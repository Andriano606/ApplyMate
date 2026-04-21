import { railsFetch } from './rails_fetch';
import * as Turbo from '@hotwired/turbo';

/**
 * Fetches content and handles both Turbo Stream and HTML responses intelligently.
 * Turbo Stream responses are rendered via Turbo.renderStreamMessage().
 * HTML responses are parsed and used to replace turbo-frame content directly.
 */
export async function turboFetch(
  url: string,
  turboFrame: Element,
  init?: RequestInit,
) {
  const headers: Record<string, string> = {
    Accept: 'text/vnd.turbo-stream.html, text/html, application/xhtml+xml',
  };

  // Add Turbo-Frame header if form is inside a turbo-frame
  if (turboFrame?.id) {
    headers['Turbo-Frame'] = turboFrame.id;
  }

  const response = await railsFetch(url, { method: 'GET', headers, ...init });

  if (response.ok) {
    const contentType = response.headers.get('Content-Type') || '';
    const streamMessage = await response.text();

    if (contentType.includes('turbo-stream')) {
      // Handle Turbo Stream response
      Turbo.renderStreamMessage(streamMessage);
    } else if (contentType.includes('text/html')) {
      // Handle HTML response - find the target turbo-frame and replace its content
      if (turboFrame) {
        // Parse the HTML response and extract the turbo-frame content
        const parser = new DOMParser();
        const doc = parser.parseFromString(streamMessage, 'text/html');
        const newFrameContent = doc.querySelector(
          `turbo-frame[id="${turboFrame.id}"]`,
        );

        if (newFrameContent) {
          turboFrame.innerHTML = newFrameContent.innerHTML;
        } else {
          // Fallback: replace entire frame content with response
          turboFrame.innerHTML = streamMessage;
        }
      }
    } else {
      // Fallback to stream handling
      Turbo.renderStreamMessage(streamMessage);
    }
  } else {
    console.error('Form update failed with status:', response.status);
  }
}
