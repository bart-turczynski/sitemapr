# Build for Anthropic's OSS Scanner (https://github.com/anthropics/oss-scanner).
# The scanner builds this with the repository as the context, then audits the
# image with no network, so everything the tests and the audit need is
# installed here.
FROM rocker/r-ver:4.6.1

# Debuggers the threat model tells the scanner to use (rocker ships neither).
RUN apt-get update \
 && apt-get install -y --no-install-recommends gdb valgrind \
 && rm -rf /var/lib/apt/lists/*

# rocker freezes an image's p3m repository to a dated snapshot once its R
# version is superseded, and a raised DESCRIPTION floor then stops resolving.
# Use p3m `latest`, with CRAN itself as a fallback (as .gitlab-ci.yml does).
RUN Rscript -e 'p3m <- sub("/[0-9]{4}-[0-9]{2}-[0-9]{2}$", "/latest", getOption("repos")[[1]]); \
      cat(sprintf("options(repos = c(P3M = \"%s\", CRAN = \"https://cloud.r-project.org\"))\n", p3m), \
          file = file.path(R.home("etc"), "Rprofile.site"), append = TRUE)'

# scanner contract: the checkout lives inside the image, at /src
COPY . /src
WORKDIR /src

# Imports and Suggests, with the system libraries they need. robotstxtr is a
# Suggests that is not on CRAN yet; pak installs it from the DESCRIPTION
# `Remotes:` pin (GitLab tag). The robots tests skip when robotstxtr is
# missing, so fail the build instead of shipping an image that silently skips
# them.
RUN Rscript -e 'install.packages("pak"); stopifnot(requireNamespace("pak", quietly = TRUE))' \
 && Rscript -e 'pak::local_install_deps("/src", dependencies = TRUE, upgrade = FALSE)' \
 && Rscript -e 'stopifnot(requireNamespace("robotstxtr", quietly = TRUE))'

RUN R CMD INSTALL --preclean /src

# Smoke-test the image; failures are logged, not fatal. The build has network,
# so the live advisory audits (test-osv.R, test-security.R) are left out here;
# they skip on their own in the offline scan.
RUN Rscript -e 'testthat::test_local("/src", filter = "^(osv|security)$", invert = TRUE)' \
 || echo "WARNING: tests reported failures"
