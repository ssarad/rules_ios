load("//rules/internal:objc_provider_utils.bzl", "objc_provider_utils")
load("//rules:utils.bzl", "is_bazel_7")
load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain", "use_cpp_toolchain")
load("@build_bazel_rules_apple//apple/internal:bundling_support.bzl", "bundling_support")
load("@build_bazel_rules_apple//apple/internal:providers.bzl", "AppleFrameworkImportInfo", "new_appleframeworkimportinfo")

_FindImportsAspectInfo = provider(fields = {
    "imported_library_file": "",
    "static_framework_file": "",
    "dynamic_framework_file": "",
    "import_infos": "",
})

def _update_framework(ctx, framework):
    # Updates the `framework` for Apple Silicon
    out_file = ctx.actions.declare_file(ctx.attr.name + "/" + framework.basename + ".framework" + "/" + framework.basename)
    cmd = """
     set -e
     TOOL="{}"
     INPUT_FRAMEWORK_BINARY="{}"
     OUTPUT_FRAMEWORK_BINARY="{}"
     INPUT_FW_DIR="$(dirname "$INPUT_FRAMEWORK_BINARY")"
     OUTPUT_FW_DIR="$(dirname "$OUTPUT_FRAMEWORK_BINARY")"

     # Duplicate the _entire_ input framework
     mkdir -p "$OUTPUT_FW_DIR"

     ditto "$INPUT_FW_DIR" "$OUTPUT_FW_DIR"
     "$TOOL" "$OUTPUT_FW_DIR/$(basename "$INPUT_FRAMEWORK_BINARY")"
   """.format(ctx.files.update_in_place[0].path, framework.path, out_file.path)

    ctx.actions.run_shell(
        outputs = [out_file],
        inputs = depset([framework] + ctx.attr.update_in_place[DefaultInfo].default_runfiles.files.to_list()),
        command = cmd,
        execution_requirements = {"no-remote": "1"},
    )
    return out_file

def _update_lib(ctx, imported_library):
    # Updates the `imported_library` for Apple Silicon
    out_file = ctx.actions.declare_file(ctx.attr.name + "/" + imported_library.basename)
    cmd = """
     set -e

     TOOL="{}"
     BINARY="{}"
     OUT="{}"

     # Duplicate the _entire_ input library
     mkdir -p "$(dirname "$BINARY")"
     ditto "$BINARY" "$OUT"
     "$TOOL" "$OUT"
   """.format(ctx.files.update_in_place[0].path, imported_library.path, out_file.path)

    ctx.actions.run_shell(
        outputs = [out_file],
        inputs = depset([imported_library]),
        command = cmd,
        execution_requirements = {"no-remote": "1"},
    )
    return out_file

def _make_imports(transitive_sets):
    provider_fields = {}
    if len(transitive_sets):
        provider_fields["framework_imports"] = depset(transitive_sets)

    provider_fields["build_archs"] = depset(["arm64"])
    provider_fields["debug_info_binaries"] = depset(transitive_sets)

    # TODO: consider passing along the dsyms
    provider_fields["dsym_imports"] = depset()
    return [new_appleframeworkimportinfo(**provider_fields)]

def _find_imports_impl(target, ctx):
    static_framework_file = []
    imported_library_file = []
    dynamic_framework_file = []
    import_infos = {}

    deps_to_search = []
    if hasattr(ctx.rule.attr, "deps"):
        deps_to_search = ctx.rule.attr.deps
    if hasattr(ctx.rule.attr, "transitive_deps"):
        deps_to_search = deps_to_search + ctx.rule.attr.transitive_deps

    for dep in deps_to_search:
        if _FindImportsAspectInfo in dep:
            static_framework_file.append(dep[_FindImportsAspectInfo].static_framework_file)
            imported_library_file.append(dep[_FindImportsAspectInfo].imported_library_file)
            dynamic_framework_file.append(dep[_FindImportsAspectInfo].dynamic_framework_file)
            import_infos.update(dep[_FindImportsAspectInfo].import_infos)

    if AppleFrameworkImportInfo in target:
        if CcInfo in target:
            for linker_input in target[CcInfo].linking_context.linker_inputs.to_list():
                for library_to_link in linker_input.libraries:
                    if library_to_link.static_library:
                        static_framework_file.append(depset([library_to_link.static_library]))

    return [_FindImportsAspectInfo(
        dynamic_framework_file = depset(transitive = dynamic_framework_file),
        imported_library_file = depset(transitive = imported_library_file),
        static_framework_file = depset(transitive = static_framework_file),
        import_infos = import_infos,
    )]

find_imports = aspect(
    implementation = _find_imports_impl,
    attr_aspects = ["transitve_deps", "deps"],
    doc = """
Internal aspect for the `import_middleman` see below for a description.
""",
)

# Returns an updated array inputs with new_inputs if they exist
def _replace_inputs(ctx, inputs, new_inputs, update_fn):
    replaced = []
    updated_inputs = {}
    for f in new_inputs:
        out = update_fn(ctx, f)
        updated_inputs[f] = out
        replaced.append(out)

    for f in inputs.to_list():
        if not updated_inputs.get(f, False):
            replaced.append(f)
    return struct(inputs = replaced, replaced = updated_inputs)

def _merge_linked_inputs(deps):
    all_static_framework_file = [depset()]
    all_imported_library_file = [depset()]
    all_dynamic_framework_file = [depset()]
    all_import_infos = {}
    for dep in deps:
        if _FindImportsAspectInfo in dep:
            all_static_framework_file.append(dep[_FindImportsAspectInfo].static_framework_file)
            all_imported_library_file.append(dep[_FindImportsAspectInfo].imported_library_file)
            all_dynamic_framework_file.append(dep[_FindImportsAspectInfo].dynamic_framework_file)
            all_import_infos.update(dep[_FindImportsAspectInfo].import_infos)

    input_static_frameworks = depset(transitive = all_static_framework_file).to_list()
    input_imported_libraries = depset(transitive = all_imported_library_file).to_list()
    input_dynamic_frameworks = depset(transitive = all_dynamic_framework_file).to_list()

    return (input_static_frameworks, input_imported_libraries, input_dynamic_frameworks, all_import_infos)

def _deduplicate_test_deps(test_deps, deps):
    filtered = []
    if len(test_deps) == 0:
        return deps
    for dep in deps:
        if not dep in test_deps:
            filtered.append(dep)
    return filtered

def _file_collector_rule_impl(ctx):
    cc_toolchain = find_cpp_toolchain(ctx)
    cc_features = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        language = "objc",
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )

    linker_deps = _merge_linked_inputs(ctx.attr.deps)
    test_linker_deps = _merge_linked_inputs(ctx.attr.test_deps)
    input_static_frameworks = _deduplicate_test_deps(test_linker_deps[0], linker_deps[0])
    input_imported_libraries = _deduplicate_test_deps(test_linker_deps[1], linker_deps[1])
    input_dynamic_frameworks = _deduplicate_test_deps(test_linker_deps[2], linker_deps[2])
    all_import_infos = linker_deps[3]

    arch = ctx.fragments.apple.single_arch_cpu
    platform = str(ctx.fragments.apple.single_arch_platform.platform_type)
    is_sim_arm64 = platform == "ios" and arch == "arm64" and not ctx.fragments.apple.single_arch_platform.is_device
    if not is_sim_arm64:
        # This should be correctly configured upstream: see setup in rules_ios
        fail("using import_middleman ({}) on wrong transition ({},{},is_device={})".format(ctx.attr.name, platform, arch, ctx.fragments.apple.single_arch_platform.is_device))

    merge_keys = [
    ]

    objc_provider_fields = objc_provider_utils.merge_objc_providers_dict(
        providers = [],
        merge_keys = merge_keys,
    )

    exisiting_imported_libraries = objc_provider_fields.get("imported_library", depset([]))
    replaced_imported_libraries = _replace_inputs(ctx, exisiting_imported_libraries, input_imported_libraries, _update_lib).inputs
    objc_provider_fields["imported_library"] = depset(_deduplicate_test_deps(test_linker_deps[1], replaced_imported_libraries))

    existing_static_framework = objc_provider_fields.get("static_framework_file", depset([]))

    deduped_static_framework = depset(_deduplicate_test_deps(test_linker_deps[0], existing_static_framework.to_list()))

    replaced_static_framework = _replace_inputs(ctx, deduped_static_framework, input_static_frameworks, _update_framework)
    objc_provider_fields["imported_library"] = depset([], transitive = [
        depset(replaced_static_framework.inputs),
        objc_provider_fields.get("imported_library", depset([])),
    ])

    # Update dynamic frameworks - note that we need to do some additional
    # processing for the ad-hoc files e.g. ( Info.plist )
    exisiting_dynamic_framework = objc_provider_fields.get("dynamic_framework_file", depset([]))
    deduped_dynamic_framework = depset(_deduplicate_test_deps(test_linker_deps[2], exisiting_dynamic_framework.to_list()))
    dynamic_framework_file = []
    dynamic_framework_dirs = []
    replaced_dynamic_framework = {}
    for f in input_dynamic_frameworks:
        out = _update_framework(ctx, f)
        replaced_dynamic_framework[f] = out
        dynamic_framework_file.append(out)
        dynamic_framework_dirs.append(out)

        # Append ad-hoc framework files by name: e.g. ( Info.plist )
        ad_hoc_file = all_import_infos[f.path].framework_imports.to_list()

        # Remove the input framework files from this rule
        ad_hoc_file.remove(f)
        dynamic_framework_dirs.extend(ad_hoc_file)

    for f in deduped_dynamic_framework.to_list():
        if not replaced_dynamic_framework.get(f, False):
            dynamic_framework_file.append(f)
            dynamic_framework_dirs.append(f)
    objc_provider_fields["dynamic_framework_file"] = depset(dynamic_framework_file)

    all_replaced_frameworks = replaced_dynamic_framework.values() + replaced_static_framework.replaced.values()
    replaced_frameworks = replaced_dynamic_framework.values()

    compat_link_opt = ["-L__BAZEL_XCODE_DEVELOPER_DIR__/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/iphonesimulator", "-Wl,-weak-lswiftCompatibility51"]

    if len(all_replaced_frameworks):
        # Triple quote the new path to put them first. Eliminating other paths
        # may possible but needs more handling of other kinds of frameworks and
        # has edge cases that require baking assumptions to handle.
        objc_provider_fields["linkopt"] = depset(
            ["\"\"\"-F" + "/".join(f.path.split("/")[:-2]) + "\"\"\"" for f in replaced_frameworks] + compat_link_opt,
            transitive = [objc_provider_fields.get("linkopt", depset([]))],
        )

    objc_provider_fields["link_inputs"] = depset(
        transitive = [
            objc_provider_fields.get("link_inputs", depset([])),
            depset(all_replaced_frameworks),
        ],
    )

    objc = apple_common.new_objc_provider(
        **objc_provider_fields
    )

    dep_cc_infos = [dep[CcInfo] for dep in ctx.attr.deps if CcInfo in dep]
    cc_info = cc_common.merge_cc_infos(cc_infos = dep_cc_infos)
    if is_bazel_7:
        # Need to recreate linking_context for Bazel 7 or later
        # because of https://github.com/bazelbuild/bazel/issues/16939
        cc_info = CcInfo(
            compilation_context = cc_info.compilation_context,
            linking_context = cc_common.create_linking_context(
                linker_inputs = depset([
                    cc_common.create_linker_input(
                        owner = ctx.label,
                        user_link_flags = compat_link_opt if len(all_replaced_frameworks) else [],
                        libraries = depset([
                            cc_common.create_library_to_link(
                                actions = ctx.actions,
                                cc_toolchain = cc_toolchain,
                                feature_configuration = cc_features,
                                static_library = static_library,
                                alwayslink = False,
                            )
                            for static_library in replaced_static_framework.replaced.values()
                        ]),
                    ),
                ]),
            ),
        )
    return [
        DefaultInfo(files = depset(dynamic_framework_dirs + replaced_frameworks)),
        objc,
        cc_info,
    ] + _make_imports(dynamic_framework_dirs)

import_middleman = rule(
    implementation = _file_collector_rule_impl,
    fragments = ["apple", "cpp"],
    toolchains = use_cpp_toolchain(),
    attrs = {
        "deps": attr.label_list(aspects = [find_imports]),
        "test_deps": attr.label_list(aspects = [find_imports], allow_empty = True),
        "update_in_place": attr.label(executable = True, default = Label("//tools/m1_utils:update_in_place"), cfg = "exec"),
        "_cc_toolchain": attr.label(
            providers = [cc_common.CcToolchainInfo],
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
            doc = """\
The C++ toolchain from which linking flags and other tools needed by the Swift
toolchain (such as `clang`) will be retrieved.
""",
        ),
    },
    doc = """
This rule adds the ability to update the Mach-o header on imported
libraries and frameworks to get arm64 binaires running on Apple silicon
simulator. For rules_ios, it's added in `app.bzl` and `test.bzl`

Why bother doing this? Well some apps have many dependencies which could take
along time on vendors or other parties to update. Because the M1 chip has the
same ISA as ARM64, most binaries will run transparently. Most iOS developers
code is high level enough and isn't specifc to a device or simulator. There are
many caveats and eceptions but getting it running is better than nothing. ( e.g.
`TARGET_OS_SIMULATOR` )

This solves the problem at the build system level with the power of bazel. The
idea is pretty straight forward:
1. collect all imported paths
2. update the macho headers with Apples vtool and arm64-to-sim
3. update the linker invocation to use the new libs

Now it updates all of the inputs automatically - the action can be taught to do
all of this conditionally if necessary.

Note: The action happens in a rule for a few reasons.  This has an interesting
propery: you get a single path for framework lookups at linktime. Perhaps this
can be updated to work without the other behavior
""",
)
