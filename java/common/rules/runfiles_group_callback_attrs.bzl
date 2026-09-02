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
Attribute fragments pointing the Java rules at their runfiles group callbacks.

`_runfiles_group_callback` is the well-known attribute name specified by
`@rules_runfiles_group//runfiles_group:callback.bzl%RUNFILES_GROUP_CALLBACK_ATTR`.
A packaging ruleset attaches one language-agnostic aspect, which reads this
attribute off every target it visits and asks the target it names to describe that
target's runfiles as groups. See `//java:runfiles_group_support.bzl` for the
callback targets themselves.

The name is spelled out here rather than loaded from `@rules_runfiles_group`, and
this file loads nothing at all, so that the Java rule definitions keep no load-time
dependency on that module. They cannot afford one: rules_java is in Bazel's
WORKSPACE autoload set, where an extra load edge out of a rule `.bzl` reintroduces
a resolution cycle (https://github.com/bazelbuild/bazel/issues/23043).
`test/java/bazel/rules/runfiles_group_tests.bzl` asserts that the spelling below
still matches the constant.
"""

# copybara: default visibility

LIBRARY_RUNFILES_GROUP_CALLBACK_ATTRS = {
    "_runfiles_group_callback": attr.label(default = Label("//java:runfiles_group_callback_library")),
}

IMPORT_RUNFILES_GROUP_CALLBACK_ATTRS = {
    "_runfiles_group_callback": attr.label(default = Label("//java:runfiles_group_callback_import")),
}

BINARY_RUNFILES_GROUP_CALLBACK_ATTRS = {
    "_runfiles_group_callback": attr.label(default = Label("//java:runfiles_group_callback_binary")),
}
