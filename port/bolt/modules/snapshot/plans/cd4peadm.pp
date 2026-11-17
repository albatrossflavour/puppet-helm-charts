# Evaluate cd4peadm's own config() against fixture data and return it as data.
plan snapshot::cd4peadm() {
  return snapshot::to_data(cd4peadm::config())
}
