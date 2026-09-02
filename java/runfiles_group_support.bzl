# Copyright 2026 The Bazel Authors. All rights reserved.
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

"""
Describes the runfiles of Java targets as named, ordered groups.

A packaging rule -- a container-image or archive rule -- gets a better artifact out
of a `java_binary` if it can see the runfiles as groups instead of as one flat tree:
the JDK changes far less often than third-party jars, which change far less often
than the application's own code, so splitting them apart makes the expensive layers
the cacheable ones.

## For users of the Java rules

Nothing to do. Ask your packaging ruleset to attach
`@rules_runfiles_group//runfiles_group:aspect.bzl%runfiles_group_aspect` -- rules_img
already does -- and build with
`--@rules_runfiles_group//runfiles_group:enabled=true`. Groups are off by default,
because a build that packages nothing should not pay for them.

The groups a Java binary is split into:

  * `rules_java#java_runtime` -- the JDK, at `RANK_FOUNDATION`, `do_not_merge`.
  * one group per `java_import`, at `RANK_SHARED_DEPS`, kind `third_party`.
  * one group per `java_library` and one for the binary's own jars, at
    `RANK_EXECUTABLE`, kind `first_party` only in the main repository -- plenty of
    the Java that Bazel builds from source belongs to somebody else.
  * `rules_java#binary` -- the launcher stub, at `RANK_EXECUTABLE`. This is the
    `executable_group`, so it also receives the runfiles symlinks and the repo
    mapping manifest.

Every group carries the `rules_java` merge affinity, so JVM-shaped groups stay
together when a packager has to merge them to fit a layer limit. A `java_import`
carries its `runfiles_weight`, if set, so the packager can merge the small ones
first.

## How it is wired up

The Java rules do not return `RunfilesGroupInfo` themselves and do not load
`@rules_runfiles_group`. Each of them carries a `_runfiles_group_callback`
attribute (see `//java/common/rules:runfiles_group_callback_attrs.bzl`) pointing at
one of the three targets in `//java`, and each of those returns
`RunfilesGroupCallbackInfo` holding the function below that knows how to describe
that family of rule. The aspect a packager attaches reads the attribute, calls the
function, and never learns it was looking at Java.

Dispatch is by which target a rule points at, not by `ctx.rule.kind`: a rule kind is
only a name, and another ruleset may reuse it.
"""

load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_runfiles_group//runfiles_group:callback.bzl", "RunfilesGroupCallbackInfo")
load("@rules_runfiles_group//runfiles_group:lib.bzl", "runfiles_groups")
load("@rules_runfiles_group//runfiles_group:providers.bzl", "RunfilesGroupInfo")
load("//java/private:java_info.bzl", "JavaInfo")

# Stamped on every group the Java rules describe, so that JVM-shaped groups stay
# together when a packager has to merge groups to fit a layer limit.
MERGE_AFFINITY = "rules_java"

# The two groups every java_binary and java_test contributes beyond its own jars.
# Both are shared by every binary, so they are named with strings rather than with
# a Label.
JAVA_RUNTIME_GROUP = "rules_java#java_runtime"
BINARY_GROUP = "rules_java#binary"

# Hardcoded rather than read from //java/common:java_semantics.bzl (where it is
# semantics.JAVA_RUNTIME_TOOLCHAIN_TYPE): this file is loaded by //java/BUILD, and
# semantics pulls in bazel_features, whose generated repositories are the other
# half of the WORKSPACE autoload problem this design exists to avoid.
_JAVA_RUNTIME_TOOLCHAIN_TYPE = "@bazel_tools//tools/jdk:runtime_toolchain_type"

# The answer for a target that is ours and contributes nothing at runtime: a
# neverlink library has no runtime jars and no default runfiles. Saying None here
# instead would mean "I cannot describe this", and the caller would synthesize a
# group named after a target that ships nothing. Built once at load time -- an
# empty provider is immutable and shared by every neverlink target in the build.
_NOTHING_AT_RUNTIME = RunfilesGroupInfo(entries = depset())

def own_kind(label):
    """Returns the `kind` of the group holding a target's own outputs.

    Only a target in the main repository is first-party. Plenty of Java targets
    Bazel builds from source belong to somebody else -- the protobuf runtime, say
    -- and a packaging rule that selects on `kind` should not have to treat those
    as the user's own code.

    Args:
      label: (Label) The label of the target owning the group.

    Returns:
      (str) One of runfiles_groups.KINDS.
    """
    return "first_party" if label.repo_name == "" else "third_party"

# --------------------------------------------------------------- describe functions

def _binary_groups(target, ctx, java_runtime_files):
    """Describes a java_binary or java_test.

    Args:
      target: (Target) The binary being described.
      ctx: (AspectContext) The aspect's context; the binary's attributes are
        ctx.rule.attr.
      java_runtime_files: (depset[File]|None) The JDK, resolved by the callback
        target, or None if no java_runtime toolchain was available.

    Returns:
      (RunfilesGroupInfo)
    """
    attrs = ctx.rule.attr
    label = target.label

    # Not runtime_output_jars: to_java_binary_info() zeroes that (and
    # transitive_runtime_jars) for a binary. The class jar is <name>.jar, not
    # lib<name>.jar, and it is on the runtime classpath whether or not the binary
    # has sources.
    own = _own_entry(
        label,
        [output.class_jar for output in target[JavaInfo].java_outputs if output.class_jar],
        kind = own_kind(label),
        rank = runfiles_groups.RANK_EXECUTABLE,
    )

    executable = target[DefaultInfo].files_to_run.executable
    executable_group = None
    if executable:
        if java_runtime_files == None:
            fail(("{}: no @bazel_tools//tools/jdk:runtime_toolchain_type was resolved for " +
                  "//java:runfiles_group_callback_binary, so the JDK in this binary's runfiles " +
                  "would end up in no runfiles group. Register a java_runtime toolchain, or " +
                  "stop packaging this target from its runfiles groups -- an image built from " +
                  "groups that do not hold the JDK does not run.").format(label))

        # java_runtime_files is only reached for a target with an executable,
        # which is also the only case where bazel_base_binary_impl() merges the
        # JDK into the runfiles.
        own.append(runfiles_groups.entry(
            name = JAVA_RUNTIME_GROUP,
            content = java_runtime_files,
            kind = "foundation",
            rank = runfiles_groups.RANK_FOUNDATION,
            do_not_merge = True,
            merge_affinity = MERGE_AFFINITY,
        ))
        own.append(runfiles_groups.entry(
            name = BINARY_GROUP,
            content = depset([executable]),
            kind = own_kind(label),
            rank = runfiles_groups.RANK_EXECUTABLE,
            merge_affinity = MERGE_AFFINITY,
        ))
        executable_group = BINARY_GROUP

    deps = [
        getattr(attrs, "deps", []),
        getattr(attrs, "runtime_deps", []),
    ]

    # Mirrors java_helper.get_test_support: the test runner is merged into the
    # runfiles under exactly these conditions.
    test_support = getattr(attrs, "_test_support", None)
    if executable and getattr(attrs, "use_testrunner", False) and test_support != None:
        deps.append(test_support)

    data = [getattr(attrs, "data", [])]
    launcher = _launcher(attrs) if executable else None
    if launcher != None:
        data.append(launcher)

    return RunfilesGroupInfo(
        entries = _collect_entries(ctx, deps = deps, data = data, own = own),
        executable_group = executable_group,
    )

def _library_groups(target, ctx, _payload):
    """Describes a java_library.

    Args:
      target: (Target) The library being described.
      ctx: (AspectContext) The aspect's context.
      _payload: Unused; the library callback carries none.

    Returns:
      (RunfilesGroupInfo)
    """
    attrs = ctx.rule.attr
    if getattr(attrs, "neverlink", False):
        return _NOTHING_AT_RUNTIME

    label = target.label

    # runtime_output_jars is [classjar] when the library has sources or resources
    # and [] when it only re-exports, which is exactly compilation_info.runfiles --
    # what the rule puts in its own runfiles. java_outputs[*].class_jar would also
    # list the never-shipped jar of a source-less library.
    own = _own_entry(
        label,
        target[JavaInfo].runtime_output_jars,
        kind = own_kind(label),
        rank = runfiles_groups.RANK_EXECUTABLE,
    )

    return RunfilesGroupInfo(entries = _collect_entries(
        ctx,
        deps = [
            getattr(attrs, "deps", []),
            getattr(attrs, "exports", []),
            getattr(attrs, "runtime_deps", []),
        ],
        data = [getattr(attrs, "data", [])],
        own = own,
    ))

def _import_groups(target, ctx, _payload):
    """Describes a java_import.

    Args:
      target: (Target) The import being described.
      ctx: (AspectContext) The aspect's context.
      _payload: Unused; the import callback carries none.

    Returns:
      (RunfilesGroupInfo)
    """
    attrs = ctx.rule.attr
    if getattr(attrs, "neverlink", False):
        return _NOTHING_AT_RUNTIME

    # An import's jars come from somewhere else by definition, so they are
    # third_party at the shared-deps rank regardless of which repository the
    # target itself is in.
    weight = getattr(attrs, "runfiles_weight", 0)
    own = _own_entry(
        target.label,
        target[JavaInfo].runtime_output_jars,
        kind = "third_party",
        rank = runfiles_groups.RANK_SHARED_DEPS,
        weight = weight if weight > 0 else None,
    )

    return RunfilesGroupInfo(entries = _collect_entries(
        ctx,
        deps = [
            getattr(attrs, "deps", []),
            getattr(attrs, "exports", []),
            getattr(attrs, "runtime_deps", []),
        ],
        data = [getattr(attrs, "data", [])],
        own = own,
    ))

# ---------------------------------------------------------------------- helpers

def _own_entry(label, jars, *, kind, rank, weight = None):
    """The [entry] a target contributes for its own jars, or [] if it has none.

    A target with no jars of its own -- a library that only re-exports -- gets no
    group at all rather than an empty one, so a packager does not have to place a
    layer that holds nothing.
    """
    if not jars:
        return []
    return [runfiles_groups.entry(
        name = label,
        content = depset(jars),
        kind = kind,
        rank = rank,
        weight = weight,
        merge_affinity = MERGE_AFFINITY,
    )]

def _launcher(attrs):
    """The launcher whose runfiles basic_java_binary() merges in, or None.

    Mirrors java_helper.filter_launcher_for_target. The default value of the
    `launcher` attribute is @bazel_tools//tools/jdk:launcher_flag_alias, which does
    not have cc_common.launcher_provider -- a real cc_binary does, and then its
    whole DefaultInfo lands in the binary's runfiles.
    """
    if not getattr(attrs, "use_launcher", True):
        return None
    launcher = getattr(attrs, "launcher", None)
    if launcher and cc_common.launcher_provider in launcher:
        return launcher
    return None

def _collect_entries(ctx, *, deps, data, own):
    """Returns the runfiles group entries of a target and of its dependencies.

    Dependencies that provide RunfilesGroupInfo propagate their entries by
    reference. Those that do not get one synthesized entry each: unlike a ruleset
    whose own rules all speak the protocol, a Java target's dependency may well be
    a custom rule that returns JavaInfo -- rules_jvm_external's jvm_import, say --
    and lands in a binary's runtime classpath and runfiles without being
    describable. Not covering those would silently drop their files from every
    group.

    Args:
      ctx: (AspectContext) Used to synthesize entries and to read the providers.
      deps: (list[Target|list[Target]]) Attribute values holding the dependencies
        whose groups this target propagates.
      data: (list[Target|list[Target]]) Attribute values holding arbitrary targets,
        passed through to runfiles_groups.collect().
      own: (list[entry]) The entries this target owns.

    Returns:
      (depset[entry]) The entries of this target and of its dependencies.
    """
    participating = []
    entries = list(own)
    for dep in _targets(deps):
        if RunfilesGroupInfo in dep:
            participating.append(dep)
        else:
            entry = _foreign_entry(ctx, dep)
            if entry:
                entries.append(entry)

    return runfiles_groups.collect(
        ctx,
        deps = participating,
        data = data,
        own = entries,
    )

def _targets(attr_values):
    """Flattens attribute values holding a single Target or a list of them."""
    targets = []
    for value in attr_values:
        if type(value) == "Target":
            targets.append(value)
        else:
            targets.extend(value)
    return targets

def _foreign_entry(ctx, dep):
    """Synthesizes the entry of a dependency that provides no runfiles groups.

    It covers the two channels a Java target draws a dependency's runfiles from:
    the runtime classpath, built from the dependency's transitive runtime jars, and
    the dependency's own default runfiles, which a target collects implicitly. Both
    are empty for a neverlink dependency, which contributes nothing at runtime and
    therefore needs no group.

    Deliberately not DefaultInfo.files, which runfiles_groups.data_entry() would
    include: a neverlink java_library publishes its jars there while contributing
    nothing to a binary's runfiles, and a group holding a file that is not in the
    runfiles is as wrong as one missing a file that is.

    Args:
      ctx: (AspectContext) Used to union the two content forms.
      dep: (Target) A dependency without RunfilesGroupInfo.

    Returns:
      (entry|None) The dependency's entry, or None if it contributes nothing.
    """
    contents = []
    if JavaInfo in dep:
        contents.append(dep[JavaInfo].transitive_runtime_jars)
    default_runfiles = dep[DefaultInfo].default_runfiles
    if default_runfiles != None:
        contents.append(default_runfiles)
    if not contents:
        return None

    return runfiles_groups.entry(
        name = dep.label,
        content = runfiles_groups.union(ctx, contents),
        merge_affinity = MERGE_AFFINITY,
    )

# -------------------------------------------------------------- callback targets

_DESCRIBE = {
    "library": _library_groups,
    "import": _import_groups,
}

def _java_runfiles_group_callback_impl(ctx):
    return [RunfilesGroupCallbackInfo(describe = _DESCRIBE[ctx.attr.rule_family])]

java_runfiles_group_callback = rule(
    implementation = _java_runfiles_group_callback_impl,
    doc = """\
Publishes the function describing the runfiles groups of a family of Java rules.

Instantiated once per family in //java. Point a rule at one of those targets with
the `_runfiles_group_callback` attribute fragments in
//java/common/rules:runfiles_group_callback_attrs.bzl; a packaging rule attaching
`runfiles_group_aspect` then finds it.

java_binary and java_test need the JDK, which only toolchain resolution can supply,
so they use java_binary_runfiles_group_callback instead.
""",
    attrs = {
        "rule_family": attr.string(
            mandatory = True,
            values = sorted(_DESCRIBE),
            doc = "Which family of Java rules this callback describes.",
        ),
    },
    provides = [RunfilesGroupCallbackInfo],
)

def _java_binary_runfiles_group_callback_impl(ctx):
    # A language-agnostic aspect cannot declare a Java toolchain type -- an aspect
    # only resolves types it named at load time -- so it cannot see the JDK. This
    # target can: it is an implicit dependency of the binary in the binary's own
    # configuration, so it resolves the same java_runtime the binary did,
    # --java_runtime_version transitions included.
    toolchain = ctx.toolchains[_JAVA_RUNTIME_TOOLCHAIN_TYPE]
    return [RunfilesGroupCallbackInfo(
        describe = _binary_groups,
        payload = toolchain.java_runtime.files if toolchain else None,
    )]

java_binary_runfiles_group_callback = rule(
    implementation = _java_binary_runfiles_group_callback_impl,
    doc = """\
Publishes the function describing the runfiles groups of java_binary and java_test,
together with the JDK those rules put in their runfiles.

The toolchain is optional here and mandatory on the binary itself: a binary that
resolved no java_runtime has none in its runfiles either, and failing during a
packaging rule's aspect would only obscure the rule's own error.
""",
    toolchains = [config_common.toolchain_type(_JAVA_RUNTIME_TOOLCHAIN_TYPE, mandatory = False)],
    provides = [RunfilesGroupCallbackInfo],
)
