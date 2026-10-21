export async function fetchJson(url, options = {}) {
  const response = await fetch(url, {
    headers: {
      "Content-Type": "application/json",
    },
    ...options,
  });

  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    const parts = [payload.error || `Request failed: ${response.status}`];
    if (payload.detail) {
      parts.push(payload.detail);
    }
    if (payload.guidance) {
      parts.push(payload.guidance);
    }
    throw new Error(parts.filter(Boolean).join(" "));
  }
  return payload;
}

export function postJson(url, payload) {
  return fetchJson(url, {
    method: "POST",
    body: JSON.stringify(payload),
  });
}
