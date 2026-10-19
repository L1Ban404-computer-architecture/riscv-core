#include "ras.hpp"

#include <stdexcept>

Ras::Ras(const RasConfig &config) {
  if (config.method != "none" && config.method != "stack") {
    throw std::invalid_argument("ras must be none or stack");
  }
  if (config.method == "none") return;
  if (config.depth == 0) throw std::invalid_argument("ras-depth must be positive");
  entries_.resize(config.depth);
}

std::optional<std::uint32_t> Ras::Peek() const {
  if (count_ == 0) return std::nullopt;
  return entries_[(next_ + entries_.size() - 1u) % entries_.size()];
}

void Ras::Push(std::uint32_t address) {
  if (entries_.empty()) return;
  entries_[next_] = address;
  next_ = (next_ + 1u) % entries_.size();
  if (count_ < entries_.size()) ++count_;
}

void Ras::Pop() {
  if (count_ == 0) return;
  next_ = (next_ + entries_.size() - 1u) % entries_.size();
  --count_;
}
