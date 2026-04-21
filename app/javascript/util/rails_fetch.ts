import Rails from '@rails/ujs';
import { handleErrors } from './error_handler';

export async function railsFetch(
  input: RequestInfo | URL,
  init?: RequestInit,
): Promise<Response> {
  if (!init) {
    init = {};
  }

  // Normalize headers to Headers object
  const headers = new Headers(init.headers);

  // Set Content-Type if needed
  const type = contentType(headers, init.body);
  if (type) {
    headers.set('Content-Type', type);
  }

  if (!headers.has('Accept')) {
    headers.set('Accept', 'application/json');
  }

  // Always set CSRF token
  headers.set('X-CSRF-Token', Rails.csrfToken());

  init.headers = headers;

  const response = fetch(input, init);

  response.then(handleErrors).catch(() => {});

  return response;
}

function contentType(headers: Headers, body: any) {
  if (headers.has('Content-Type')) {
    return null; // Don't override existing Content-Type
  } else if (body == null || body instanceof window.FormData) {
    return undefined;
  } else if (body instanceof window.File) {
    return body.type;
  }

  return 'application/json';
}
