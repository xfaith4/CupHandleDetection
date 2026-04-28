export async function requestJson(url, options = {}) {
  const { body, headers, ...rest } = options;
  const finalHeaders = {
    Accept: "application/json",
    ...headers,
  };

  let payloadBody = body;
  if (body && typeof body !== "string" && !(body instanceof FormData)) {
    finalHeaders["Content-Type"] = "application/json";
    payloadBody = JSON.stringify(body);
  }

  const response = await fetch(url, {
    ...rest,
    headers: finalHeaders,
    body: payloadBody,
  });

  const payload = await response.json().catch(() => ({
    message: `Request failed for ${url}`,
  }));

  if (!response.ok) {
    const error = new Error(payload.message || `Request failed with status ${response.status}`);
    error.status = response.status;
    error.detail = payload.detail || "";
    error.payload = payload;
    throw error;
  }

  return payload;
}
