function registerMergeRoutes(app, {store, requireAuth}) {
  app.get("/v1/merge-proposals/pending", requireAuth, async (req, res) => {
    const requestedLimit = Number(req.query.limit || 50);
    // SPEED-13: этот маршрут не проходит через requireTreeAccess (не
    // tree-scoped), поэтому req.storeSnapshot обычно не выставлен —
    // читаем общий замороженный снимок сами (0 клона на попадании кэша
    // на PostgresStore, см. readSharedSnapshot). listPendingMergeProposalsForUser
    // сам решает, нужна ли материализация (_mutate) поверх снимка.
    const prefetchedDb = req.storeSnapshot || (await store.readSharedSnapshot());
    const proposals = await store.listPendingMergeProposalsForUser(
      req.auth.user.id,
      {
        limit: Number.isFinite(requestedLimit) ? requestedLimit : 50,
      },
      prefetchedDb,
    );
    res.json({proposals});
  });

  app.post(
    "/v1/merge-proposals/:proposalId/review",
    requireAuth,
    async (req, res) => {
      const reviewed = await store.reviewMergeProposal({
        proposalId: req.params.proposalId,
        reviewerUserId: req.auth.user.id,
        decision: req.body?.decision,
        reason: req.body?.reason,
      });
      if (reviewed === null) {
        res.status(404).json({message: "Предложение не найдено"});
        return;
      }
      if (reviewed === false) {
        res.status(403).json({message: "Нет доступа к этому предложению"});
        return;
      }
      res.json({proposal: reviewed});
    },
  );

  // D1: применённые слияния зрителя — секция «Объединённые ранее».
  app.get("/v1/merge-proposals/merged", requireAuth, async (req, res) => {
    const requestedLimit = Number(req.query.limit || 50);
    const proposals = await store.listMergedProposalsForUser(
      req.auth.user.id,
      {
        limit: Number.isFinite(requestedLimit) ? requestedLimit : 50,
      },
    );
    res.json({proposals});
  });

  // D1: разъединить применённое слияние. Право — любой из
  // ответственных (reviewerUserIds).
  app.post(
    "/v1/merge-proposals/:proposalId/unmerge",
    requireAuth,
    async (req, res) => {
      const result = await store.unmergeMergeProposal({
        proposalId: req.params.proposalId,
        actorUserId: req.auth.user.id,
      });
      if (result === null) {
        res.status(404).json({message: "Предложение не найдено"});
        return;
      }
      if (result === false) {
        res.status(403).json({message: "Нет доступа к этому предложению"});
        return;
      }
      if (result?.error === "legacy") {
        res.status(409).json({
          message:
            "Это объединение сделано до появления журнала слияний — " +
            "разъединить его автоматически не получится. Напишите нам, " +
            "поможем вручную.",
        });
        return;
      }
      if (result?.error === "not_applied") {
        res.status(409).json({
          message: "Это предложение ещё не объединено — разъединять нечего.",
        });
        return;
      }
      res.json({proposal: result});
    },
  );
}

module.exports = {
  registerMergeRoutes,
};
