"""Java rules with FSManifestInfo support."""

load("@fsmanifestinfo//fsmanifest:fsmanifestinfo.bzl", "fsmanifest")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")

def _categorize_java_file(file):
    """Categorize Java files by their source.

    Args:
        file: File object

    Returns:
        Category string: "runtime", "third_party", or "app"
    """
    path = file.short_path

    # Check if it's a JRE/JDK runtime file
    if "jdk" in path.lower() or "jre" in path.lower() or path.startswith("remotejdk"):
        return "runtime"

    # Check if it's from an external repository (third-party)
    if file.owner:
        workspace = file.owner.workspace_name
        if workspace and workspace != "" and workspace != "__main__":
            return "third_party"

    # Check path-based heuristics for external dependencies
    if path.startswith("external/"):
        # Maven dependencies
        if "maven" in path or "m2" in path:
            return "third_party"
        # Other external repos
        if not path.startswith("external/bazel_tools/"):
            return "third_party"

    # Default to app code
    return "app"

def _java_binary_fsmanifest_aspect_impl(target, ctx):
    """Aspect that adds FSManifestInfo to java_binary targets."""

    # Build FSManifestInfo from the target's runfiles
    entries = {}

    # Get runfiles from the target
    if hasattr(target, "default_runfiles"):
        runfiles = target.default_runfiles

        # Process all files in runfiles
        for file in runfiles.files.to_list():
            category = _categorize_java_file(file)

            # Determine destination path based on category
            if category == "runtime":
                dest_path = "/runtime/" + file.short_path.split("/")[-1]
            elif category == "third_party":
                # For Maven deps, try to preserve some structure
                if "maven" in file.short_path:
                    # Extract the jar name and parent directory
                    parts = file.short_path.split("/")
                    if len(parts) >= 2:
                        dest_path = "/deps/" + "/".join(parts[-2:])
                    else:
                        dest_path = "/deps/" + parts[-1]
                else:
                    dest_path = "/deps/" + file.basename
            else:  # app
                dest_path = "/app/" + file.basename

            entries[dest_path] = fsmanifest.make_entry(
                src = file,
                kind = "file",
                category = category,
                mode = "0755" if file.basename.endswith(".sh") or file.is_executable else "0644",
            )

    # Add the main executable if present
    if hasattr(target, "files_to_run") and target.files_to_run and target.files_to_run.executable:
        exec_file = target.files_to_run.executable
        entries["/app/bin/" + exec_file.basename] = fsmanifest.make_entry(
            src = exec_file,
            kind = "file",
            category = "app",
            mode = "0755",
        )

    # Also process JavaInfo if available
    if JavaInfo in target:
        java_info = target[JavaInfo]

        # Add runtime classpath jars
        if hasattr(java_info, "runtime_output_jars"):
            for jar in java_info.runtime_output_jars:
                category = _categorize_java_file(jar.class_jar)
                if category == "third_party":
                    dest_path = "/deps/" + jar.class_jar.basename
                else:
                    dest_path = "/app/lib/" + jar.class_jar.basename

                entries[dest_path] = fsmanifest.make_entry(
                    src = jar.class_jar,
                    kind = "file",
                    category = category,
                    mode = "0644",
                )

    # Create the FSManifestInfo provider
    manifest_info = fsmanifest.create_manifest(
        entries = entries,
        labels = {
            "target": str(ctx.label),
            "type": "java_binary",
        },
    )

    return [manifest_info]

java_binary_fsmanifest_aspect = aspect(
    implementation = _java_binary_fsmanifest_aspect_impl,
    attr_aspects = [],
)