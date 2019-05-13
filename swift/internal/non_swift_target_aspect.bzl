# Copyright 2018 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Attaches `SwiftInfo` providers as needed to non-Swift targets in the dependency graph.

There are two reasons to attach a `SwiftInfo` provider to non-Swift targets:

*   For a `cc_library`, we want to generate a module map so that it can be imported directly by
    Swift, as well as propagate the merged `SwiftInfo`s of its children so that information from
    those dependencies isn't lost. (For example, consider a `swift_library` that depends on an
    `objc_library` that depends on a `swift_library`.)

    The modules generated by this aspect have names that are automatically derived from the label
    of the `cc_library` target, using the same logic used to derive the module names for Swift
    targets.

*   For any other target, we want to propagate the merged `SwiftInfo`s of its children so that
    types defined in those modules are available to the parent modules. For example, if a Swift
    target indirectly depends on another Swift target through an Objective-C target, the
    Objective-C target's implementation doesn't know that it needs to propagate the Swift info,
    so the aspect handles that.

    The exception to this is C++ dependencies, where we explicitly discard indirect dependencies
    because we don't have a good way to handle some of the targets that show up in those graphs
    yet.

This aspect is an implementation detail of the Swift build rules and is not meant to be attached
to other rules or run independently.
"""

load("@bazel_skylib//lib:paths.bzl", "paths")
load(":api.bzl", "swift_common")
load(":derived_files.bzl", "derived_files")
load(":features.bzl", "SWIFT_FEATURE_MODULE_MAP_HOME_IS_CWD")
load(":providers.bzl", "SwiftInfo", "SwiftToolchainInfo")
load(":utils.bzl", "get_providers")

def _explicit_module_name(tags):
    """Returns an explicit module name specified by a tag of the form `"swift_module=Foo"`.

    Since tags are unprocessed strings, nothing prevents the `swift_module` tag from being listed
    multiple times on the same target with different values. For this reason, the aspect uses the
    _last_ occurrence that it finds in the list.

    Args:
        tags: The list of tags from the `cc_library` target to which the aspect is being applied.

    Returns:
        The desired module name if it was present in `tags`, or `None`.
    """
    module_name = None
    for tag in tags:
        if tag.startswith("swift_module="):
            _, _, module_name = tag.partition("=")
    return module_name

def _header_path(file, module_map, workspace_relative):
    """Returns the path to a header file as it should be written into the module map.

    Args:
        file: A `File` representing the header whose path should be returned.
        module_map: A `File` representing the module map being written, which is used during path
            relativization if necessary.
        workspace_relative: A Boolean value indicating whether the path should be
            workspace-relative or module-map-relative.

    Returns:
        The path to the header file, relative to either the workspace or the module map as
        requested.
    """

    # If the module map is workspace-relative, then the file's path is what we want.
    if workspace_relative:
        return file.path

    # Otherwise, since the module map is generated, we need to get the full path to it rather than
    # just its short path (that is, the path starting with bazel-out/). Then, we can simply walk up
    # the same number of parent directories as there are path segments, and append the header
    # file's path to that.
    num_segments = len(paths.dirname(module_map.path).split("/"))
    return ("../" * num_segments) + file.path

def _write_module_map(
        actions,
        module_map,
        module_name,
        hdrs = [],
        textual_hdrs = [],
        workspace_relative = False):
    """Writes the content of the module map to a file.

    Args:
        actions: The actions object from the aspect context.
        module_map: A `File` representing the module map being written.
        module_name: The name of the module being generated.
        hdrs: The value of `attr.hdrs` for the target being written (which is a list of targets
            that are either source files or generated files).
        textual_hdrs: The value of `attr.textual_hdrs` for the target being written (which is a
            list of targets that are either source files or generated files).
        workspace_relative: A Boolean value indicating whether the path should be
            workspace-relative or module-map-relative.
    """
    content = "module {} {{\n".format(module_name)

    # TODO(allevato): Should we consider moving this to an external tool to avoid the analysis time
    # expansion of these depsets? We're doing this in the initial version because these sets tend
    # to be very small.
    for target in hdrs:
        content += "".join([
            '    header "{}"\n'.format(_header_path(header, module_map, workspace_relative))
            for header in target.files.to_list()
        ])
    for target in textual_hdrs:
        content += "".join([
            '    textual header "{}"\n'.format(_header_path(header, module_map, workspace_relative))
            for header in target.files.to_list()
        ])
    content += "    export *\n"
    content += "}\n"

    actions.write(output = module_map, content = content)

def _non_swift_target_aspect_impl(target, aspect_ctx):
    # Do nothing if the target already propagates `SwiftInfo`.
    if SwiftInfo in target:
        return []

    attr = aspect_ctx.rule.attr

    # It's not great to depend on the rule name directly, but we need to access the exact `hdrs`
    # and `textual_hdrs` attributes (which may not be propagated distinctly by a provider) and
    # also make sure that we don't pick up rules like `objc_library` which already handle module
    # map generation.
    # TODO(allevato): Can `CcInfo.compilation_context` propagate these headers distinctly?
    if aspect_ctx.rule.kind == "cc_library":
        # If there's an explicit module name, use it; otherwise, auto-derive one using the usual
        # derivation logic for Swift targets.
        module_name = _explicit_module_name(attr.tags)
        if not module_name:
            if "/" in target.label.name or "+" in target.label.name:
                return []
            module_name = swift_common.derive_module_name(target.label)

        # Determine if the toolchain requires module maps to use workspace-relative paths or not.
        toolchain = aspect_ctx.attr._toolchain_for_aspect[SwiftToolchainInfo]
        feature_configuration = swift_common.configure_features(
            ctx = aspect_ctx,
            requested_features = aspect_ctx.features,
            swift_toolchain = toolchain,
            unsupported_features = aspect_ctx.disabled_features,
        )
        workspace_relative = swift_common.is_enabled(
            feature_configuration = feature_configuration,
            feature_name = SWIFT_FEATURE_MODULE_MAP_HOME_IS_CWD,
        )

        module_map = derived_files.module_map(aspect_ctx.actions, target.label.name)
        _write_module_map(
            actions = aspect_ctx.actions,
            hdrs = attr.hdrs,
            module_map = module_map,
            module_name = module_name,
            textual_hdrs = attr.textual_hdrs,
            workspace_relative = workspace_relative,
        )

        # TODO(b/118311259): Figure out how to handle transitive dependencies, in case a C-only
        # module incldues headers from another C-only module. We currently have a lot of targets
        # with labels that clash when mangled into a Swift module name, so we need to figure out
        # how to handle those (either by adding the `swift_module` tag to them, or opting them in
        # some other way). So for now, when we hit a `cc_library` target, we explicitly discard any
        # of the Swift info from its dependencies.
        return [swift_common.create_swift_info(
            modulemaps = [module_map],
            module_name = module_name,
        )]

    # If it's any other rule, just merge the `SwiftInfo` providers from its deps.
    deps = getattr(attr, "deps", [])
    swift_infos = get_providers(deps, SwiftInfo)
    if swift_infos:
        return [swift_common.create_swift_info(swift_infos = swift_infos)]

    return []

non_swift_target_aspect = aspect(
    attrs = swift_common.toolchain_attrs(toolchain_attr_name = "_toolchain_for_aspect"),
    attr_aspects = ["deps"],
    fragments = ["cpp"],
    implementation = _non_swift_target_aspect_impl,
)