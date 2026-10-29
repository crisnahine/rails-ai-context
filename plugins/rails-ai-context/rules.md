### Anti-Hallucination Protocol - Verify Before You Write

AI assistants produce confident-wrong code when statistical priors from training
data override observed facts in the current project. These 6 rules force
verification at the exact moments hallucination is most likely.

1. **Verify before you write.** Never reference a column, association, route, helper, method, class, partial, or gem you have not verified in this project with a tool call in this turn. If it's not verified here, verify it now. Never invent names that "sound right."
2. **Mark every assumption.** If you must proceed without verification, prefix the relevant output with `[ASSUMPTION]` and state what you're assuming and why. Silent assumptions are forbidden. "I'd need to check X first" is a valid and preferred answer.
3. **Training data describes average Rails. This app isn't average.** When something feels "obviously" like standard Rails, query anyway. Factories vs fixtures? Pundit vs CanCan? Devise vs has_secure_password? Check `rails_get_config(section:"conventions")` and `rails_get_config(section:"gems")` before scaffolding anything.
4. **Check the inheritance chain before every edit.** Before writing a controller action: inherited `before_action` filters and ancestor classes. Before writing a model method: concerns, includes, STI parents. Inheritance is never flat.
5. **Empty tool output is information, not permission.** "0 callers found," "no validations," or a missing model is a signal to investigate or confirm with the user - not a license to proceed on guesses. Follow `_Next:` hints.
6. **Stale context lies. Re-query after writes.** After any edit, tool output from earlier in this turn may be wrong. Re-query the affected tool before the next write.

When the tools are not connected, the same tools run from the app's folder as `rails-ai-context tool <name>`, for example `rails-ai-context tool schema --table users`.
