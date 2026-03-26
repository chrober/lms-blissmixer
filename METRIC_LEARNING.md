# BlissMixer Metric Learning -- Implementation Overview

This document describes the metric learning survey feature added to the
lms-blissmixer LMS plugin.  The feature lets users train a personalised
Mahalanobis distance matrix through an "odd-one-out" survey.  The trained
matrix is then used by the bliss-mixer binary (via its `--matrix` flag) to
improve single-seed similarity searches.

The implementation is based on
[bliss-metric-learning](https://github.com/Polochon-street/bliss-metric-learning)
by Polochon-street.


## Architecture at a Glance

```
Settings page                          Survey page
(blissmixer.html)                     (survey.html)
       |                                    |
       | JSON-RPC                           | HTTP GET/POST
       v                                    v
   Plugin.pm  -->  Survey.pm  <--  survey-api handler
       |               |
       |               |---> learn.py ---> metric_core.py
       |               |        (Python 3 + numpy)
       v               v
   bliss-mixer      bliss.db
   (Rust binary)    (training_triplet table)
```


## Files

### Perl -- Plugin Integration

| File | Role |
|------|------|
| `Plugin.pm` | Dispatches `survey` CLI commands to `Survey.pm`.  Passes `--matrix` to bliss-mixer when `learned_matrix.json` exists. |
| `Survey.pm` | All survey logic: HTTP handlers, CLI actions, Python detection, pip install, learning process management. |
| `Settings.pm` | Injects template variables (button labels, strings) into the settings page. |
| `strings.txt` | EN/DE string definitions for survey/learning UI elements. |

### Python -- Metric Learning

| File | Role |
|------|------|
| `metric_core.py` | **Upstream-synced** math functions (distance, gradient, triplet loss, evaluation).  Direct port from bliss-metric-learning.  Only depends on numpy + stdlib math. |
| `learn.py` | Adapter: data loading from TracksV2, CLI interface, JSON progress output, scipy/sklearn fallback backends.  Imports core math from `metric_core.py`. |

### HTML/JS -- User Interface

| File | Role |
|------|------|
| `settings/blissmixer.html` | Settings page.  "Metric Learning" collapsible section with survey link, triplet count, matrix status, install/learn/clear buttons, Python status notes. |
| `survey.html` | Standalone survey page.  Presents 3 songs with audio players; user picks the odd one out. |


## Data Flow

### 1. Survey (Collecting Training Data)

1. User opens the survey page (`/blissmixer/survey.html`).
2. JS fetches 3 random songs via `GET /blissmixer/survey-api?action=songs`.
3. `Survey.pm` queries `TracksV2` in `bliss.db`, resolves each file to an LMS
   track object, returns JSON with `title`, `artist`, `album`, `audio_url`.
4. Browser renders 3 `<audio>` elements.  User listens, selects the odd one out.
5. JS POSTs `{song_1_id, song_2_id, odd_one_out_id}` to `/blissmixer/survey-api`.
6. `Survey.pm` inserts a row into the `training_triplet` table and returns the
   new total count.
7. JS auto-loads the next round.

### 2. Learning (Training the Matrix)

1. User clicks "Run Learning" on the settings page.
2. JS sends `blissmixer survey act:run-learning` via JSON-RPC.
3. `Survey.pm::_startLearning()` validates prerequisites (Python found, numpy
   installed, at least 10 triplets), then launches `learn.py` as a background
   process via `Proc::Background`.
4. A `Slim::Utils::Timers` timer polls every 5 seconds until the process exits.
5. `learn.py` loads triplets from `bliss.db`, runs 5-fold cross-validation over
   a lambda grid, trains a final model on all data, and writes
   `learned_matrix.json`.
6. On completion, `Survey.pm` calls `Plugin::_stopMixer()` so the next mix
   request restarts bliss-mixer with `--matrix`.

### 3. Mixing (Using the Matrix)

1. `Plugin.pm::_startMixer()` checks if `learned_matrix.json` exists.
2. If so, it appends `--matrix <path>` to the bliss-mixer command line.
3. bliss-mixer's `load_learned_matrix()` reads the 23x23 matrix and uses it
   for Mahalanobis distance calculations, especially when only one seed track
   is available (where variance-based dynamic weighting can't operate).


## Database Schema

The survey uses a single new table in the existing `bliss.db`:

```sql
CREATE TABLE IF NOT EXISTS training_triplet (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    song_1_id       INTEGER NOT NULL,   -- rowid from TracksV2 (similar to song_2)
    song_2_id       INTEGER NOT NULL,   -- rowid from TracksV2 (similar to song_1)
    odd_one_out_id  INTEGER NOT NULL,   -- rowid from TracksV2 (the outlier)
    stamp           DATETIME DEFAULT CURRENT_TIMESTAMP
);
```

Song IDs reference `rowid` in the existing `TracksV2` table (the 23-column
bliss feature table populated by bliss-analyser).


## Python Dependencies and Environment

### Required

- **Python 3** (detected via `python3`, `python`, `/usr/local/bin/python3`,
  `/usr/bin/python3`)
- **numpy** (only hard dependency)

### Optional (auto-detected at runtime)

- **scipy** -- provides `scipy.optimize.minimize` (L-BFGS-B) and
  `scipy.stats.norm` (CDF/PDF).  When absent, `learn.py` uses a numpy-only
  L-BFGS implementation and `math.erf`-based normal distribution.
- **scikit-learn** -- provides `KFold` and `train_test_split`.  When absent,
  `learn.py` uses numpy random permutation equivalents.

### Python environment on piCorePlayer

LMS on piCorePlayer (pCP) runs as user `tc` with `HOME=/root` (not writable).
To handle this:

- `Survey.pm::init()` sets `$ENV{PYTHONUSERBASE}` to
  `<LMS prefs dir>/python-packages` (e.g.
  `/usr/local/slimserver/prefs/python-packages`).
- pip installs use `--user` (writes to `PYTHONUSERBASE` instead of system
  site-packages).
- pip installs use `--break-system-packages` on Python 3.11+ (PEP 668).
- If pip itself is missing, `ensurepip --user` is attempted first.
- pCP's Python 3.12 TCZ package is missing `_ctypes`, which prevents scipy
  from loading.  The numpy-only fallback handles this gracefully.


## Settings Page UI (Metric Learning Section)

The "Metric Learning" section is a collapsible panel in the settings page,
following the same pattern as the "Analyser" and "Mixer" sections.

### Elements

- **Survey link** -- opens `/blissmixer/survey.html` in a new tab.
- **Training triplets count** -- polled every 5 seconds via JSON-RPC.
- **Matrix status** -- "Available" or "Not yet generated".
- **Python status note** -- conditionally shown:
  - `ready`: hidden (all good).
  - `missing_packages`: red text listing missing packages + "Install required
    packages" button.
  - `no_python`: red text "Python 3 is required but was not found".
- **Run Learning / Stop Learning** button -- disabled when Python isn't ready.
- **Clear Training Data** button -- with confirmation dialog.
- **Status line** -- shows learning progress or install output.

### Python Status Detection

`Survey.pm::_pythonStatus()` returns a hash with:

```perl
{ status => 'ready',            python => '/usr/bin/python3' }
{ status => 'missing_packages', python => '/usr/bin/python3', missing => ['numpy'] }
{ status => 'no_python' }
```

Each candidate binary is tested with `--version` (must contain "Python 3"),
then each required package is tested with `python -c "import <module>"`.


## metric_core.py -- Upstream Sync Strategy

The core math is extracted into `metric_core.py` to keep the upstream-shared
code isolated and diffable.

### What's in metric_core.py

All functions that are a direct copy of the upstream bliss-metric-learning
`learn.py`:

| Function | Purpose |
|----------|---------|
| `d(L, x1, x2)` | Mahalanobis distance: `sqrt((x1-x2)^T L L^T (x1-x2))` |
| `grad_d(L, x1, x2)` | Gradient of `d` w.r.t. `L` |
| `grad_d_squared(L, x1, x2)` | Gradient of `d^2` w.r.t. `L` |
| `delta(L, x1, x2, x3, sigma)` | Normalised distance difference for triplet |
| `grad_delta(...)` | Gradient of `delta` |
| `p(...)` | Triplet probability via normal CDF (crowd-kernel model) |
| `grad_p(...)` | Gradient of `p` |
| `log_p(...)` | Log-probability |
| `grad_log_p(...)` | Gradient of log-probability |
| `opti_fun(L, X, sigma, l)` | Objective: negative log-likelihood + L2 regularisation |
| `grad_opti_fun(L, X, sigma, l)` | Gradient of objective |
| `percentage_preserved_distances(L, X)` | Evaluation: fraction of triplets where learned metric preserves the correct ordering |

### What's NOT in metric_core.py

Everything specific to our adaptation stays in `learn.py`:

- Data loading (TracksV2 schema, 23 features)
- CLI argument parsing
- JSON progress output
- scipy/sklearn fallback backends (optimizer, cross-validation)
- Output format (`learned_matrix.json`)

### norm_cdf / norm_pdf Injection

`metric_core.py` defines `norm_cdf` and `norm_pdf` as module-level functions
using `math.erf` (no scipy dependency).  `learn.py` upgrades these to scipy's
versions at startup when available:

```python
import metric_core
from scipy.stats import norm as scipy_norm
metric_core.norm_cdf = lambda x: float(scipy_norm.cdf(x))
metric_core.norm_pdf = lambda x: float(scipy_norm.pdf(x))
```

Python resolves `norm_cdf(...)` calls inside `metric_core.p()` through the
module's global namespace at call time, so this replacement works correctly.

### Syncing with upstream

To check for upstream changes:

1. Fetch: `curl -O https://raw.githubusercontent.com/Polochon-street/bliss-metric-learning/master/learn.py`
2. Compare the functions `d` through `percentage_preserved_distances` against
   `metric_core.py`.
3. Copy any upstream changes directly into `metric_core.py`.

The adapter code in `learn.py` does not need to change unless function
signatures change.


## Learning Algorithm

The algorithm follows the crowd-kernel / STE (Stochastic Triplet Embedding)
approach:

1. **Input**: `N` training triplets, each consisting of three songs where the
   user identified the "odd one out".
2. **Model**: A matrix `L` (23x23) parameterising a Mahalanobis distance
   `d(x1, x2) = sqrt((x1-x2)^T M (x1-x2))` where `M = L^T L`.
3. **Objective**: Maximise the likelihood of the observed triplet responses
   under a probit model (normal CDF), plus L2 regularisation.
4. **Optimisation**: L-BFGS-B (scipy when available, custom numpy
   implementation otherwise).
5. **Hyperparameter selection**: 5-fold cross-validation over
   `lambda in {0, 0.001, 0.01, 0.1, 1, 50, 100, 500, 1000, 5000}`.
6. **Evaluation**: Fraction of held-out triplets where the learned distance
   correctly identifies the similar pair (compared to Euclidean baseline).
7. **Output**: The Mahalanobis matrix `M = L_total * L_total^T` saved as JSON:
   `{"m": {"v": 1, "dim": [23, 23], "data": [529 floats]}}`.

### Parameters

| Parameter | Value | Source |
|-----------|-------|--------|
| `sigma` | 2 | Noise parameter in the probit model (from upstream) |
| `L0` | Identity matrix (23x23, flattened) | Initial guess |
| Train/test split | 80/20 | Standard holdout |
| CV folds | 5 (or fewer if too few triplets) | Standard k-fold |
| Lambda grid | `[0, 0.001, 0.01, 0.1, 1, 50, 100, 500, 1000, 5000]` | From upstream |


## Output Format

`learned_matrix.json`:

```json
{
  "m": {
    "v": 1,
    "dim": [23, 23],
    "data": [529 float values representing M row-by-row]
  }
}
```

This matches the format expected by bliss-mixer's `load_learned_matrix()`
function in `main.rs`.


## CLI Actions

All actions are dispatched via:
`blissmixer survey act:<action>`

| Action | Description |
|--------|-------------|
| `status` | Returns triplet count, matrix existence, learning state, Python status, dep install state. |
| `run-learning` | Starts `learn.py` as a background process. |
| `stop-learning` | Kills the learning process. |
| `install-deps` | Installs numpy via pip (with `--user`, `--break-system-packages`). |
| `clear-triplets` | Deletes all rows from `training_triplet`. |
