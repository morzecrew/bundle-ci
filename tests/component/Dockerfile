# The image ci.yml builds through component-image.yml on a pull request, and
# never pushes: nothing to pull, and the build args land in a label.
FROM scratch
ARG APP__VERSION=unset
ARG APP__BUILD_ID=unset
LABEL tech.morze.selftest.version="${APP__VERSION}+${APP__BUILD_ID}"
COPY README.md /README.md
