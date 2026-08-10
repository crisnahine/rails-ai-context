# Derive Prism listener registration ourselves, not via prism's register_public_methods

Status: accepted

Prism 1.9+ ships `Dispatcher#register_public_methods`, which looks like the obvious replacement for the hand-typed event allowlist that shipped the fabricated-static-routes bug (c8caa40). We derive registration in our own module instead, for two reasons that are easy to rediscover the hard way: the gem's prism floor is below 1.9, where the helper does not exist, and the helper is built on `public_methods(false)`, which skips inherited handlers - `VariantCallListener` inherits its only handler from `ChainedCallListener` and would register zero events, silently.

(The floor was 0.28 when this was written and is 1.4 now; the first reason holds either way. See the gemspec for the current range, and the `prism floor` CI leg that tests it.)

Our module enumerates `on_*` handlers inheritance-aware and validates every name against the running prism's real event set, raising on unknowns, so an unregistered or typo'd handler fails loud instead of never firing. Do not swap the prism helper back in as a simplification; it reintroduces both silent failure modes.
