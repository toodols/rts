//! Metal spots in clusters, and each cluster's defence points, as BARb has them (CircuitAI barbarian:
//! resource/MetalData.cpp `Clusterize` and `BuildClusterGraph`, resource/MetalManager.cpp `GetSpotToBuild`,
//! setup/DefenceData.cpp):
//!
//! - spots are clustered by complete linkage (util/math/HierarchCluster.cpp: two clusters merge while the furthest pair
//!   of their spots is within economy.json's `cluster_range`), each cluster's position the middle of its spots;
//! - clusters are joined by a Delaunay triangulation of their positions, an edge costing
//!   `distance / (incomeA + incomeB) * (spotsA + spotsB)`;
//! - the spot a builder goes for (`spot_to_build`) is in the cluster nearest it along the graph, over clusters the
//!   threat map leaves safe (threat at the cluster <= THREAT_MIN), that is neither all taken nor all built and has a
//!   spot the caller accepts; of that cluster's accepted spots, the nearest to the builder;
//! - each cluster's spots are clustered again within porcupine `point_range` into defence points, where its
//!   porcupine goes, each keeping the metal of the defences at it (`cost`).
//!
//! Two simplifications: a point's position is the middle of its spots rather than the centre of the smallest circle
//! round them, and BARb's defence points at terrain choke points are left out (this game has no choke analysis).

use crate::map::P;
use std::collections::BinaryHeap;

#[derive(Clone, Debug)]
pub struct Cluster {
    pub spots: Vec<usize>,
    pub p: P,
    pub income: f64,
    pub points: Vec<usize>,
}

#[derive(Clone, Debug)]
pub struct DefPoint {
    pub p: P,
    pub cluster: usize,
    /// metal of the defences built or queued at it
    pub cost: f64,
}

pub struct Metal {
    pub spots: Vec<(P, f64)>,
    pub spot_cluster: Vec<usize>,
    pub clusters: Vec<Cluster>,
    pub edges: Vec<Vec<(usize, f64)>>,
    pub points: Vec<DefPoint>,
    /// per spot: taken (by an extractor of anyone's, or a task of its own)
    pub taken: Vec<bool>,
    /// per spot: an extractor of its own finished on it
    pub mine: Vec<bool>,
    pub cluster_avg_income: f64,
    pub cluster_max_income: f64,
    pub cluster_std: f64,
}

/// Complete-linkage clustering of `points` within `max_distance` (HierarchCluster::Clusterize).
fn complete_linkage(points: &[P], max_distance: f64) -> Vec<Vec<usize>> {
    let mut clusters: Vec<Vec<usize>> = (0..points.len()).map(|i| vec![i]).collect();
    loop {
        let mut best: Option<(f64, usize, usize)> = None;
        for i in 0..clusters.len() {
            for j in (i + 1)..clusters.len() {
                let mut far: f64 = 0.0;
                for &a in &clusters[i] {
                    for &b in &clusters[j] {
                        far = far.max(points[a].dist(points[b]));
                    }
                }
                if best.map_or(true, |(d, _, _)| far < d) {
                    best = Some((far, i, j));
                }
            }
        }
        match best {
            Some((d, i, j)) if d <= max_distance => {
                let moved = clusters.swap_remove(j);
                clusters[i].extend(moved);
            }
            _ => break,
        }
    }
    clusters
}

/// The edges of the Delaunay triangulation of `points` (Bowyer-Watson).
fn delaunay_edges(points: &[P]) -> Vec<(usize, usize)> {
    let n = points.len();
    if n < 2 {
        return Vec::new();
    }
    if n == 2 {
        return vec![(0, 1)];
    }
    let (mut minx, mut minz, mut maxx, mut maxz) = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
    for p in points {
        minx = minx.min(p.x);
        minz = minz.min(p.z);
        maxx = maxx.max(p.x);
        maxz = maxz.max(p.z);
    }
    let d = (maxx - minx).max(maxz - minz).max(1.0) * 20.0;
    let (cx, cz) = ((minx + maxx) / 2.0, (minz + maxz) / 2.0);
    let mut all: Vec<P> = points.to_vec();
    all.push(P::new(cx - d, cz - d));
    all.push(P::new(cx + d, cz - d));
    all.push(P::new(cx, cz + d));
    let mut tris: Vec<[usize; 3]> = vec![[n, n + 1, n + 2]];
    let circum = |t: &[usize; 3], all: &[P]| -> (P, f64) {
        let (a, b, c) = (all[t[0]], all[t[1]], all[t[2]]);
        let dd = 2.0 * (a.x * (b.z - c.z) + b.x * (c.z - a.z) + c.x * (a.z - b.z));
        if dd.abs() < 1e-12 {
            return (a, f64::MAX);
        }
        let ux = ((a.x * a.x + a.z * a.z) * (b.z - c.z) + (b.x * b.x + b.z * b.z) * (c.z - a.z) + (c.x * c.x + c.z * c.z) * (a.z - b.z)) / dd;
        let uz = ((a.x * a.x + a.z * a.z) * (c.x - b.x) + (b.x * b.x + b.z * b.z) * (a.x - c.x) + (c.x * c.x + c.z * c.z) * (b.x - a.x)) / dd;
        let center = P::new(ux, uz);
        (center, center.dist2(a))
    };
    for i in 0..n {
        let p = all[i];
        let mut bad = Vec::new();
        for (k, t) in tris.iter().enumerate() {
            let (c, r2) = circum(t, &all);
            if p.dist2(c) < r2 {
                bad.push(k);
            }
        }
        let mut boundary: Vec<(usize, usize)> = Vec::new();
        for &k in &bad {
            let t = tris[k];
            for (a, b) in [(t[0], t[1]), (t[1], t[2]), (t[2], t[0])] {
                let shared = bad.iter().any(|&o| {
                    o != k && {
                        let u = tris[o];
                        (u.contains(&a)) && (u.contains(&b))
                    }
                });
                if !shared {
                    boundary.push((a, b));
                }
            }
        }
        bad.sort_unstable_by(|a, b| b.cmp(a));
        for k in bad {
            tris.swap_remove(k);
        }
        for (a, b) in boundary {
            tris.push([a, b, i]);
        }
    }
    let mut edges = Vec::new();
    for t in &tris {
        for (a, b) in [(t[0], t[1]), (t[1], t[2]), (t[2], t[0])] {
            if a < n && b < n {
                let e = if a < b { (a, b) } else { (b, a) };
                if !edges.contains(&e) {
                    edges.push(e);
                }
            }
        }
    }
    edges
}

#[derive(Copy, Clone, PartialEq)]
struct Node(f64, usize);
impl Eq for Node {}
impl Ord for Node {
    fn cmp(&self, o: &Self) -> std::cmp::Ordering {
        o.0.total_cmp(&self.0).then(self.1.cmp(&o.1))
    }
}
impl PartialOrd for Node {
    fn partial_cmp(&self, o: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(o))
    }
}

impl Metal {
    /// `spots`: each spot's position and income (an extractor's metal on it); distances in studs.
    pub fn new(spots: Vec<(P, f64)>, cluster_range: f64, point_range: f64) -> Metal {
        let positions: Vec<P> = spots.iter().map(|s| s.0).collect();
        let groups = complete_linkage(&positions, cluster_range);
        let mut spot_cluster = vec![0; spots.len()];
        let mut clusters: Vec<Cluster> = Vec::new();
        for (ci, g) in groups.iter().enumerate() {
            let mut c = P::new(0.0, 0.0);
            let mut income = 0.0;
            for &s in g {
                c = c.add(spots[s].0);
                income += spots[s].1;
                spot_cluster[s] = ci;
            }
            clusters.push(Cluster { spots: g.clone(), p: c.scale(1.0 / g.len() as f64), income, points: Vec::new() });
        }
        let centers: Vec<P> = clusters.iter().map(|c| c.p).collect();
        let mut edges = vec![Vec::new(); clusters.len()];
        for (a, b) in delaunay_edges(&centers) {
            let (ca, cb) = (&clusters[a], &clusters[b]);
            let cost = ca.p.dist(cb.p) / (ca.income + cb.income).max(1e-6) * (ca.spots.len() + cb.spots.len()) as f64;
            edges[a].push((b, cost));
            edges[b].push((a, cost));
        }
        let mut points = Vec::new();
        for ci in 0..clusters.len() {
            let local: Vec<P> = clusters[ci].spots.iter().map(|&s| spots[s].0).collect();
            for g in complete_linkage(&local, point_range) {
                let c = g.iter().fold(P::new(0.0, 0.0), |a, &i| a.add(local[i])).scale(1.0 / g.len() as f64);
                clusters[ci].points.push(points.len());
                points.push(DefPoint { p: c, cluster: ci, cost: 0.0 });
            }
        }
        let n = clusters.len().max(1) as f64;
        let avg = clusters.iter().map(|c| c.income).sum::<f64>() / n;
        let max = clusters.iter().map(|c| c.income).fold(0.0, f64::max);
        let var = clusters.iter().map(|c| (c.income - avg).powi(2)).sum::<f64>() / n;
        let count = spots.len();
        Metal {
            spots,
            spot_cluster,
            clusters,
            edges,
            points,
            taken: vec![false; count],
            mine: vec![false; count],
            cluster_avg_income: avg,
            cluster_max_income: max,
            cluster_std: var.sqrt(),
        }
    }

    pub fn nearest_cluster(&self, p: P) -> Option<usize> {
        (0..self.clusters.len()).min_by(|&a, &b| self.clusters[a].p.dist2(p).total_cmp(&self.clusters[b].p.dist2(p)))
    }

    pub fn nearest_cluster_where(&self, p: P, pred: &dyn Fn(usize) -> bool) -> Option<usize> {
        (0..self.clusters.len())
            .filter(|&c| pred(c))
            .min_by(|&a, &b| self.clusters[a].p.dist2(p).total_cmp(&self.clusters[b].p.dist2(p)))
    }

    pub fn nearest_spot(&self, p: P) -> Option<usize> {
        (0..self.spots.len()).min_by(|&a, &b| self.spots[a].0.dist2(p).total_cmp(&self.spots[b].0.dist2(p)))
    }

    pub fn is_queued(&self, c: usize) -> bool {
        self.clusters[c].spots.iter().all(|&s| self.taken[s])
    }

    pub fn is_finished(&self, c: usize) -> bool {
        self.clusters[c].spots.iter().all(|&s| self.mine[s])
    }

    /// GetSpotToBuild: the spot to build on for something at `from`, over the clusters `safe` passes.
    pub fn spot_to_build(&self, from: P, safe: &dyn Fn(usize) -> bool, accept: &dyn Fn(usize) -> bool) -> Option<usize> {
        let start = self.nearest_cluster(from)?;
        if !safe(start) {
            return None;
        }
        let mut dist = vec![f64::MAX; self.clusters.len()];
        let mut heap = BinaryHeap::new();
        dist[start] = 0.0;
        heap.push(Node(0.0, start));
        while let Some(Node(d, c)) = heap.pop() {
            if d > dist[c] {
                continue;
            }
            if !self.is_queued(c) && !self.is_finished(c) {
                let found: Vec<usize> = self.clusters[c].spots.iter().copied().filter(|&s| accept(s)).collect();
                if !found.is_empty() {
                    return found.into_iter().min_by(|&a, &b| self.spots[a].0.dist2(from).total_cmp(&self.spots[b].0.dist2(from)));
                }
            }
            for &(o, cost) in &self.edges[c] {
                if !safe(o) {
                    continue;
                }
                let nd = d + cost;
                if nd < dist[o] {
                    dist[o] = nd;
                    heap.push(Node(nd, o));
                }
            }
        }
        None
    }

    /// The defence point of `cluster` nearest `p` that `pred` accepts.
    pub fn closest_point(&self, cluster: usize, p: P, pred: &dyn Fn(&DefPoint) -> bool) -> Option<usize> {
        self.clusters[cluster]
            .points
            .iter()
            .copied()
            .filter(|&i| pred(&self.points[i]))
            .min_by(|&a, &b| self.points[a].p.dist2(p).total_cmp(&self.points[b].p.dist2(p)))
    }

    pub fn has_defence(&self, cluster: usize) -> bool {
        self.clusters[cluster].points.iter().any(|&i| self.points[i].cost > 0.5)
    }
}
