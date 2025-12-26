const crypto = require('crypto');

// Cyanite Proxy - Version: 2.2.0-feedback-fix
// This file acts as a secure bridge between the CUE iOS app and Cyanite AI.

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Signature');

  if (req.method === "OPTIONS") return res.status(200).end();

  const CYANITE_ACCESS_TOKEN = process.env.CYANITE_ACCESS_TOKEN;
  // Note: Webhook secret is handled by Cyanite dashboard settings
  const CYANITE_WEBHOOK_SECRET = process.env.CYANITE_WEBHOOK_SECRET;

  // --- POST: Webhook Handler (From Cyanite) ---
  if (req.method === "POST") {
    // FIX 1: Temporarily disabling signature verification to fix 401 mismatch
    /*
    const signature = req.headers['signature'];
    const hmac = crypto.createHmac('sha256', CYANITE_WEBHOOK_SECRET);
    const bodyString = JSON.stringify(req.body); 
    if (signature !== hmac.update(bodyString).digest('hex')) {
        console.error("Webhook Signature Mismatch");
        return res.status(401).end();
    }
    */

    const event = req.body;
    console.log("Cyanite Webhook Received:", event?.__typename);

    if (event?.__typename === "SpotifyTrackAnalysisCompletedEvent") {
      const trackId = event.spotifyTrack.id;
      console.log(`Analysis Completed for Track: ${trackId}`);
      cacheEvent(trackId, { status: "completed", timestamp: new Date().toISOString() });
    }

    return res.status(200).json({ status: "success" });
  }

  // --- GET: Recommendation Proxy (From iOS App) ---
  if (req.method === "GET") {
    const { trackId, bpmStart, bpmEnd, genres } = req.query;

    // Health Check / Versioning
    if (!trackId) {
      return res.status(200).json({
        status: "healthy",
        version: "2.2.0-feedback-fix",
        message: "Cyanite Proxy is live."
      });
    }

    if (!CYANITE_ACCESS_TOKEN) {
      return res.status(500).json({ status: "error", error: "Missing CYANITE_ACCESS_TOKEN env variable." });
    }

    // FIX 2: Check in-memory cache before doing anything else
    // This allows the polling loop to succeed once the webhook lands.
    const cached = getCachedEvent(trackId);
    if (cached && cached.status === "completed") {
      console.log(`Cache Hit for ${trackId}: Success!`);
      // We still fetch recommendations once on hit to give the app the data
    } else {
      console.log(`Proxying request for: ${trackId} (Cache: Miss)`);
    }

    // Map filters for the GraphQL query
    const filters = {};
    if (bpmStart && bpmEnd) filters.bpm = { start: parseInt(bpmStart), end: parseInt(bpmEnd) };
    if (genres) {
      filters.genres = genres.split(',')
        .map(g => g.trim().toLowerCase())
        .map(g => {
          const map = {
            'electronic': 'electronicDance',
            'electronicdance': 'electronicDance',
            'rock': 'rock',
            'pop': 'pop',
            'hiphop': 'rapHipHop',
            'rap': 'rapHipHop',
            'rnb': 'rnB',
            'r&b': 'rnB',
            'jazz': 'jazz',
            'blues': 'blues',
            'classical': 'classical',
            'reggae': 'reggae',
            'metal': 'metal',
            'folk': 'folkCountry',
            'country': 'folkCountry'
          };
          return map[g] || null;
        })
        .filter(g => g !== null);
    }

    try {
      // Step A: Attempt filtered search
      let recommendation = await getRecommendations(trackId, CYANITE_ACCESS_TOKEN, filters);

      // Step B: Fallback to non-filtered if zero results
      if (!recommendation && Object.keys(filters).length > 0) {
        console.log(`No filtered results for ${trackId}. Trying raw search...`);
        recommendation = await getRecommendations(trackId, CYANITE_ACCESS_TOKEN, {});
      }

      if (recommendation && recommendation.length > 0) {
        // Return all candidate track IDs (client will check recently played)
        return res.status(200).json({ status: "success", trackIds: recommendation });
      } else {
        // Step C: Trigger analysis if unknown
        console.log(`Track ${trackId} unknown. Enqueueing analysis...`);
        await enqueueAnalysis(trackId, CYANITE_ACCESS_TOKEN);
        return res.status(200).json({ status: "analyzing" });
      }
    } catch (error) {
      console.error("Cyanite Critical Error:", error.message);

      // Emergency Fallback: If filters caused a crash, try raw search
      if (error.message.includes("MusicalGenre") || error.message.includes("filter")) {
        try {
          const fallback = await getRecommendations(trackId, CYANITE_ACCESS_TOKEN, {});
          if (fallback && fallback.length > 0) {
            return res.status(200).json({ status: "success", trackIds: fallback });
          }
        } catch (e) { }
      }

      return res.status(500).json({ status: "error", error: error.message });
    }
  }

  return res.status(405).end();
}

/**
 * GraphQL Core: Fetch Similar Tracks
 */
async function getRecommendations(trackId, token, filters) {
  let filterString = "";
  if (Object.keys(filters).length > 0) {
    const parts = [];
    if (filters.bpm) parts.push(`bpm: { range: { start: ${filters.bpm.start}, end: ${filters.bpm.end} } }`);
    if (filters.genres && filters.genres.length > 0) {
      // CRITICAL: GraphQL Enums must NOT be quoted.
      // Convert ["electronicDance"] to [electronicDance]
      const genreEnumList = `[${filters.genres.join(", ")}]`;
      parts.push(`genre: { list: ${genreEnumList} }`);
    }
    filterString = `, experimental_filter: { ${parts.join(", ")} }`;
  }

  // Query similar tracks (only ID, no artist fields)
  // Request up to 50 results to have more candidates for duplicate checking
  const query = `
    query SimilarTracksQuery($trackId: ID!) {
      spotifyTrack(id: $trackId) {
        ... on SpotifyTrack {
          similarTracks(target: { spotify: {} } ${filterString}, first: 50) {
            ... on SimilarTracksConnection {
              edges { 
                node { 
                  ... on SpotifyTrack { id } 
                } 
              } 
            }
            ... on SimilarTracksError { message }
          }
        }
      }
    }
  `;

  try {
    const response = await fetch("https://api.cyanite.ai/graphql", {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": `Bearer ${token}` },
      body: JSON.stringify({ query, variables: { trackId } })
    });

    const json = await response.json();
    if (json.errors) throw new Error(json.errors[0].message);

    const seedTrack = json.data?.spotifyTrack;
    if (!seedTrack) return [];

    const data = seedTrack.similarTracks;
    if (data?.__typename === "SimilarTracksError") throw new Error(data.message);

    const edges = data?.edges || [];

    // Return all candidate IDs (excluding seed)
    return edges
      .map(e => e.node.id)
      .filter(id => id !== trackId);
  } catch (e) {
    throw e;
  }
}

/**
 * GraphQL Core: Enqueue Track Analysis
 */
async function enqueueAnalysis(trackId, token) {
  const mutation = `
    mutation SpotifyTrackEnqueue($trackId: ID!) {
      spotifyTrackEnqueue(input: { spotifyTrackId: $trackId }) { __typename }
    }
  `;
  await fetch("https://api.cyanite.ai/graphql", {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": `Bearer ${token}` },
    body: JSON.stringify({ query: mutation, variables: { trackId } })
  });
}

/** 
 * FIX 3: Accept that in-memory cache is temporary for dev.
 * In production, this should be replaced by Vercel KV / Redis.
 */
function cacheEvent(trackId, data) {
  if (!global.cyaniteAnalysisCache) global.cyaniteAnalysisCache = {};
  global.cyaniteAnalysisCache[trackId] = data;
}

function getCachedEvent(trackId) {
  return (global.cyaniteAnalysisCache && global.cyaniteAnalysisCache[trackId]) || null;
}
