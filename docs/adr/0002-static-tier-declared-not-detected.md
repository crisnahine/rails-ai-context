# Static tier capability is declared per introspector, never auto-detected

Status: accepted

Every mapped introspector must declare how it answers in the static tier: its `call` already works from files alone, or it refuses honestly, or it defines `static_call` against an alternate static source. We rejected auto-detecting "file-only" introspectors because a default-open guess re-creates the failure mode the tier exists to prevent: an introspector that grows a runtime dependency while still looking file-only would silently serve wrong data (the c8caa40 class). Declaration fails closed - a mapped introspector that declares nothing is a spec failure, and a shared fixture spec proves every files-only declaration true under `StaticApp`.
