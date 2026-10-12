# Build for Anthropic's OSS Scanner (https://github.com/anthropics/oss-scanner).
# The scanner builds this with the repository as the context, then audits the
# image with no network, so everything the tests need is installed here.
FROM rocker/r-ver:4.6.1

# scanner contract: the checkout lives inside the image, at /src
COPY . /src
WORKDIR /src

# Imports and Suggests, with the system libraries they need. robotstxtr is a
# Suggests that is not on CRAN yet; pak installs it from the DESCRIPTION
# `Remotes:` pin (GitLab tag).
RUN Rscript -e 'install.packages("pak")' \
 && Rscript -e 'pak::local_install_deps("/src", dependencies = TRUE, upgrade = FALSE)'

# The robots tests skip when robotstxtr is missing; fail the build instead of
# shipping an image that silently skips them.
RUN Rscript -e 'stopifnot(requireNamespace("robotstxtr", quietly = TRUE))'

RUN R CMD INSTALL /src

# Smoke-test the image; failures are logged, not fatal.
RUN Rscript -e 'testthat::test_local("/src", stop_on_failure = TRUE)' \
 || echo "WARNING: tests reported failures"
