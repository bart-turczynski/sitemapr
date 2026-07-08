sitemapr_test_internal <- function(name) {
  getFromNamespace(name, "sitemapr")
}

sitemapr_test_call <- function(name, ...) {
  sitemapr_test_internal(name)(...)
}
