# Evaluate complyadm's own config() against fixture data and return it as data.
plan snapshot::complyadm() {
  return snapshot::to_data(complyadm::config())
}
