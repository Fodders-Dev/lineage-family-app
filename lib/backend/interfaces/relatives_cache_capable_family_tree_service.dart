/// Additive capability (perf(client): startup dedup, chunk
/// client/startup-dedupe) — lets code outside
/// `CustomApiFamilyTreeService` invalidate its short-TTL
/// `getRelatives()` cache for one tree.
///
/// The service's own person/relation mutation methods already
/// invalidate this cache directly (same choke point as the existing
/// graph-snapshot cache) whenever THIS device makes the change. This
/// hook covers the one case those call sites can't: a `tree_mutated`
/// realtime/push notification reporting a change made by another
/// device or family member — see
/// `CustomApiNotificationService._showBackendNotification`.
abstract class RelativesCacheCapableFamilyTreeService {
  void invalidateRelativesCache(String treeId);
}
