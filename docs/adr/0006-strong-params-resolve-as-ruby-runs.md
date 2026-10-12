# Strong params resolve a call as Ruby would run it

Status: accepted

A strong params method can return another one's answer (`params_slice(:min_id).merge(page: true)`), so whether it counts depends on what the call reaches. We decide that the way Ruby dispatches: across the controller's classes the nearest one defining the name wins, and a method counts when the one it reaches is strong params, found as a least fixpoint over the whole chain. Only a name none of those classes defines (a concern's, a gem's, Pundit's) falls back to the `*_params` or `permitted_*` name.

## Considered Options

- **Each file on its own, any other name taken at its name.** Cheap and simple, and the rule until the last fixes before v5.34.0, where a real-app check and two review rounds found wrong answers it could not fix without another special case: a parent's helper named `params_slice` dropped, a parent's non-strong `*_params` counted, a child's redefinition of a grandparent's helper ignored, a class method of the same name hiding the parent's. Do not go back to it to save the chain walk; the cost is one memoized read per source.
- **Reading concerns as classes in the chain.** Ruby puts an included module between a class and its parent, so a concern's method does win. We take a concern's name instead, because listing a concern's strong params is a new answer no surface has asked for.
