sitemapr_test_ns <- asNamespace("sitemapr")

sitemapr_test_internal <- function(name) {
  sitemapr_test_ns[[name]]
}

sitemapr_test_call <- function(name, ...) {
  sitemapr_test_internal(name)(...)
}
