"""Protoc helper rules definition for rules_proto_grpc."""

def _path(file):
    return file.path

def _short_path(file):
    return file.short_path

def build_protoc_args(
        ctx,
        plugin,
        proto_infos,
        out_arg,
        extra_options = [],
        extra_protoc_args = [],
        short_paths = False,
        resolve_tools = True):
    """
    Build the args for a protoc invocation.

    This does not include the paths to the .proto files, which should be done external to this function.

    Args:
        ctx: The Bazel rule execution context object.
        plugin: The ProtoPluginInfo for the plugin to use.
        proto_infos: The list of ProtoInfo providers.
        out_arg: The path to provide as the output arg to protoc, usually the generation root dir.
        extra_options: An optional list of extra options to pass to the plugin.
        extra_protoc_args: An optional list of extra args to add to the command.
        short_paths: Whether to use the .short_path instead of .path when creating paths. The short_path is used when
            making a test/executable and referencing the runfiles.
        resolve_tools: Whether to resolve and add the tools to returned inputs.

    Returns:
        - The list of args.
        - The inputs required for the command.
        - The input manifests required for the command.

    """

    # Specify path getter
    get_path = _short_path if short_paths else _path

    # Build inputs and manifests list
    inputs = []
    input_manifests = []

    if plugin.tool and resolve_tools:
        plugin_runfiles, plugin_input_manifests = ctx.resolve_tools(tools = [plugin.tool])
        inputs += plugin_runfiles.to_list()
        input_manifests += plugin_input_manifests

    inputs += plugin.data

    # Get plugin name
    plugin_name = plugin.name
    if plugin.protoc_plugin_name:
        plugin_name = plugin.protoc_plugin_name

    # Build args
    args_list = []

    # Load all descriptors (direct and transitive) and remove dupes
    descriptor_sets = depset([
        descriptor_set
        for proto_info in proto_infos
        for descriptor_set in proto_info.transitive_descriptor_sets.to_list()
    ]).to_list()
    inputs += descriptor_sets

    # Add descriptors
    pathsep = ctx.configuration.host_path_separator
    args_list.append("--descriptor_set_in={}".format(pathsep.join(
        [get_path(f) for f in descriptor_sets],
    )))

    # Add --plugin if not a built-in plugin
    if plugin.tool_executable:
        # If Windows, mangle the path. It's done a bit awkwardly with
        # `host_path_seprator` as there is no simple way to figure out what's
        # the current OS.
        if ctx.configuration.host_path_separator == ";":
            plugin_tool_path = get_path(plugin.tool_executable).replace("/", "\\")
        else:
            plugin_tool_path = get_path(plugin.tool_executable)

        args_list.append("--plugin=protoc-gen-{}={}".format(plugin_name, plugin_tool_path))

    # Add plugin --*_out/--*_opt args
    plugin_options = list(plugin.options)
    plugin_options.extend(extra_options)

    if plugin_options:
        opts_str = ",".join(
            [option.replace("{name}", ctx.label.name) for option in plugin_options],
        )
        if plugin.separate_options_flag:
            args_list.append("--{}_opt={}".format(plugin_name, opts_str))
        else:
            out_arg = "{}:{}".format(opts_str, out_arg)
    args_list.append("--{}_out={}".format(plugin_name, out_arg))

    # Add any extra protoc args provided or that plugin has
    extra_protoc_args_tmp = []
    extra_protoc_args_tmp.extend(extra_protoc_args)
    if plugin.extra_protoc_args:
        extra_protoc_args_tmp.extend(plugin.extra_protoc_args)

    # enable "extra_protoc_args" items to have a '{package_dir}' var that gets
    # substituted with the appropriate output location.
    rel_premerge_root = "_rpg_premerge_{}".format(ctx.label.name)
    package_dir = "{}/{}/{}".format(ctx.genfiles_dir.path, ctx.label.package, rel_premerge_root)
    for extra_protoc_arg in extra_protoc_args_tmp:
        formatted_arg = extra_protoc_arg.format(
            package_dir=package_dir,
        )
        args_list.append(formatted_arg)

    return args_list, inputs, input_manifests
