# Path Interpolation Feature (Future)

## Concept

Instead of appending a song directly to the play queue (creating an abrupt mood/style change), calculate a musical "path" of intermediate songs that gradually transition from the current mood to the target song's mood.

With a single source and a single target, this is essentially **linear interpolation** in the feature space — finding evenly spaced waypoints along a straight line. With multiple anchor points (e.g. several given songs that should appear in the playlist), it becomes true **polynomial interpolation** — fitting a smooth curve through all the anchor points in the 23D feature space.

## How It Works

1. Take the last song(s) in the queue as the **source point** (their feature vector in 23D bliss feature space)
2. Take the target song as the **destination point** (its feature vector)
3. Divide the line between source and destination into N+1 segments (N = number of transition songs)
4. For each intermediate waypoint, find the **closest real song** in the library (excluding already-selected songs and songs already in the queue)
5. Insert those transition songs + the target into the queue

Example with 3 transition songs: waypoints at 25%, 50%, 75% of the distance between source and destination. Each waypoint snaps to the nearest real track in the database.

## Repos Involved

### bliss-mixer (Rust) — New API Endpoint

A new endpoint, e.g. `POST /api/path`:

- **Input**: source track(s), target track, max transition count, optional feature weights
- **Processing**:
  - Compute intermediate feature vectors via linear interpolation (lerp)
  - For each waypoint, find nearest neighbor from the full DB (greedy, excluding already-picked tracks)
- **Output**: ordered list of tracks: `[transition1, transition2, ..., target]`

### lms-blissmixer (Plugin.pm) — New CLI Command

- New command, e.g. `blissmixer path <target_track> <num_steps>`
- Calls the new bliss-mixer endpoint
- Inserts the returned tracks into the queue

### lms-material — UI Trigger

- New context menu item on any song: e.g. "Transition to this song" or "Bridge to this song"
- Similar to the existing "Similar tracks" menu entry that uses the `blissmixer://` ProtocolHandler

## Design Considerations

### Number of Transition Songs

Two strategies:

1. **Fixed**: User configures a maximum (2-5), always uses that many.
2. **Distance-adaptive**: Compute the Euclidean distance between source and target in the feature space, scale the transition count proportionally (short distance = 1-2 songs, large distance = 4-5). Cap at the user's configured maximum.

Distance-adaptive feels more natural — a small mood shift shouldn't force 5 transition songs.

### Feature Weighting

Use the same weights as the current mixing algorithm (static or dynamic). That way the "path" respects the same priorities the user has configured for general mixing. The distance calculation and nearest-neighbor search should use the weighted distance metric.

### Greedy vs. Optimal Path Selection

- **Greedy** (pick best match for waypoint 1, then 2, then 3): Simple, fast, should work well with 50K+ tracks in the library.
- **Global optimum** (minimize total path cost across all waypoints simultaneously): Significantly more complex, probably not noticeably better given the track count.

Recommendation: start with greedy.

### Source Point Definition

Options for what constitutes the "source" in the feature space:

- Last single song in the queue
- Average of last N songs (smooths out outliers)
- Weighted average favoring more recent songs

Starting with the single last song is simplest and most predictable.

## Potential Issues

### Curse of Dimensionality

With 23 dimensions and ~50K tracks, some waypoints might snap to songs that aren't particularly close to the ideal interpolated point. However, this is mitigated by:

- Having enough transition steps so each individual jump is small
- The snapping-to-real-songs being self-correcting (each step is a real, musically coherent song)

### "Unmusical" Interpolation Paths

Linear interpolation assumes the feature space is "musically linear". In practice, a straight line from jazz to metal in 23D might pass through a region where the nearest real songs are something unexpected (e.g. polka). Mitigations:

- More transition steps reduce the per-step distance
- The library's actual coverage naturally constrains the path to plausible songs
- Users can set a low max transition count if they prefer shorter, more direct transitions
- Use external knowledge sources (e.g. last.fm, Spotify, MusicBrainz) to filter or prioritize candidates along the interpolation path. For example, candidate songs at a waypoint could be ranked not just by feature-space distance but also by genre/tag similarity to the source and target artists, ensuring the path stays within musically plausible territory.

### Sparse Regions in Feature Space

If the user's library has genre gaps, some waypoints may snap to songs that feel out of place. This is fundamentally a library coverage issue, not an algorithm issue. No mitigation needed — the algorithm does the best it can with available tracks.

### Duplicate Avoidance

Each selected transition song must be excluded from candidates for subsequent waypoints. Also need to exclude songs already in the current play queue to avoid repetition.

## User-Facing Configuration

- **Max transition songs**: integer, range 2-5 (or 1-5), configurable in settings
- **Distance-adaptive mode**: on/off toggle — if on, use fewer transition songs for shorter distances
- Possibly exposed as a simple "Transition length" setting: Short (2) / Medium (3) / Long (5)

## Related Ideas

### Playlist Generation from Anchor Songs

Given a handful of songs (e.g. 4-5), generate a playlist of N songs where the given songs are distributed more or less evenly across the playlist. Between each pair of anchor songs, use interpolation to fill in transition songs from the library. With multiple anchor points, this becomes polynomial interpolation — fitting a smooth curve through all anchor points in the feature space rather than just connecting two endpoints with a straight line.

Example: Given songs A, B, C and a target playlist length of 15, place A at position 1, B at position 8, C at position 15, and fill the gaps (2-7, 9-14) with songs that smoothly transition between the anchors.

### Playlist Re-ordering (Smoothest Path)

Given an existing playlist (or a set of songs), re-order them to find the "smoothest" path — i.e. minimize the total feature-space distance across consecutive songs. This is essentially the **Travelling Salesman Problem** (TSP) in the 23D feature space. While exact TSP is NP-hard, good approximate solutions exist:

- **Nearest-neighbor heuristic**: Start from the first song, always pick the closest unvisited song next. Fast but not optimal.
- **2-opt improvement**: Start with any ordering, repeatedly swap pairs of songs if it reduces total path distance. Good balance of quality and speed.
- **Simulated annealing**: Probabilistic optimization, can escape local minima. More complex but produces better results.

For typical playlist sizes (20-200 songs), even simple heuristics should produce noticeably smoother transitions than a random or manually curated order.
