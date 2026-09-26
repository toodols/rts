"""A plain CMA-ES (Hansen's "The CMA Evolution Strategy: A Tutorial", the standard (mu/mu_w, lambda) form with rank-one
and rank-mu updates), kept small and whole so that its state can be checkpointed as JSON. It minimises; the search
hands it minus the fitness. Coordinates live in the unit cube; a sample outside it is clipped when it is decoded, and
the clipped point is what is told back, so the distribution learns where the walls are.
"""

from __future__ import annotations

import math
from typing import Any

import numpy as np


class CMAES:
    def __init__(self, mean: list[float], sigma: float, population: int | None = None, seed: int = 0):
        n = len(mean)
        self.n = n
        self.mean = np.array(mean, dtype=float)
        self.sigma = float(sigma)
        self.lam = population or 4 + int(3 * math.log(n))
        self.mu = self.lam // 2
        weights = np.array([math.log(self.mu + 0.5) - math.log(i + 1) for i in range(self.mu)])
        self.weights = weights / weights.sum()
        self.mueff = 1.0 / float((self.weights**2).sum())
        self.cc = (4 + self.mueff / n) / (n + 4 + 2 * self.mueff / n)
        self.cs = (self.mueff + 2) / (n + self.mueff + 5)
        self.c1 = 2 / ((n + 1.3) ** 2 + self.mueff)
        self.cmu = min(1 - self.c1, 2 * (self.mueff - 2 + 1 / self.mueff) / ((n + 2) ** 2 + self.mueff))
        self.damps = 1 + 2 * max(0.0, math.sqrt((self.mueff - 1) / (n + 1)) - 1) + self.cs
        self.chin = math.sqrt(n) * (1 - 1 / (4 * n) + 1 / (21 * n * n))
        self.pc = np.zeros(n)
        self.ps = np.zeros(n)
        self.C = np.eye(n)
        self.generation = 0
        self.rng = np.random.default_rng(seed)

    def ask(self) -> list[list[float]]:
        """lambda new points, mirrored in pairs (x and its reflection through the mean) to halve the sampling noise."""
        values, vectors = np.linalg.eigh(self.C)
        values = np.maximum(values, 1e-20)
        root = vectors @ np.diag(np.sqrt(values))
        points = []
        for index in range(self.lam):
            if index % 2 == 0:
                z = self.rng.standard_normal(self.n)
                step = root @ z
            else:
                step = -step
            points.append(list(np.clip(self.mean + self.sigma * step, 0.0, 1.0)))
        return points

    def tell(self, points: list[list[float]], costs: list[float]) -> None:
        order = np.argsort(costs)
        xs = np.array(points)[order[: self.mu]]
        old = self.mean.copy()
        self.mean = self.weights @ xs
        values, vectors = np.linalg.eigh(self.C)
        values = np.maximum(values, 1e-20)
        inv_root = vectors @ np.diag(1 / np.sqrt(values)) @ vectors.T
        y = (self.mean - old) / self.sigma
        self.ps = (1 - self.cs) * self.ps + math.sqrt(self.cs * (2 - self.cs) * self.mueff) * (inv_root @ y)
        norm = float(np.linalg.norm(self.ps))
        hsig = norm / math.sqrt(1 - (1 - self.cs) ** (2 * (self.generation + 1))) / self.chin < 1.4 + 2 / (self.n + 1)
        self.pc = (1 - self.cc) * self.pc + (hsig * math.sqrt(self.cc * (2 - self.cc) * self.mueff)) * y
        ys = (xs - old) / self.sigma
        rank_mu = (ys.T * self.weights) @ ys
        delta = (1 - hsig) * self.cc * (2 - self.cc)
        self.C = (
            (1 - self.c1 - self.cmu) * self.C
            + self.c1 * (np.outer(self.pc, self.pc) + delta * self.C)
            + self.cmu * rank_mu
        )
        self.C = (self.C + self.C.T) / 2
        self.sigma *= math.exp((self.cs / self.damps) * (norm / self.chin - 1))
        # keep it searching: in a noisy problem a collapsing step size only chases the noise
        self.sigma = float(min(max(self.sigma, 0.03), 0.5))
        self.generation += 1

    def state(self) -> dict[str, Any]:
        return {
            "mean": self.mean.tolist(),
            "sigma": self.sigma,
            "lam": self.lam,
            "pc": self.pc.tolist(),
            "ps": self.ps.tolist(),
            "C": self.C.tolist(),
            "generation": self.generation,
            "rng": self.rng.bit_generator.state,
        }

    @classmethod
    def restore(cls, saved: dict[str, Any]) -> "CMAES":
        es = cls(saved["mean"], saved["sigma"], saved["lam"])
        es.pc = np.array(saved["pc"])
        es.ps = np.array(saved["ps"])
        es.C = np.array(saved["C"])
        es.generation = saved["generation"]
        es.rng.bit_generator.state = saved["rng"]
        return es
