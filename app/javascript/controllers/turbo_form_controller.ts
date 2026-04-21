import { Controller } from '@hotwired/stimulus';
import { turboFetch } from '../util/turbo_fetch';

export default class extends Controller {
  static values = { url: String };

  declare hasUrlValue: boolean;
  declare urlValue: string;
  #formGetAction!: string;
  #activeRequest: AbortController | null = null;

  connect() {
    this.element.addEventListener('turbo:submit-start', () =>
      this.#handleSubmitStart(),
    );
    this.element.addEventListener('turbo:submit-end', (event) =>
      this.#handleSubmitEnd(event),
    );

    if (this.hasUrlValue) {
      this.#formGetAction = this.urlValue;
    } else {
      let form = this.element as HTMLFormElement;
      let method =
        (form.querySelector('input[name="_method"]') as HTMLInputElement)
          ?.value || form.method;
      this.#formGetAction =
        method == 'post' ? `${form.action}/new` : `${form.action}/edit`;
    }
  }

  disconnect() {
    // Cancel any outstanding update request
    this.#activeRequest?.abort();
    this.#activeRequest = null;
  }

  async update(event: Event) {
    let target:
      | HTMLButtonElement
      | HTMLInputElement
      | HTMLTextAreaElement
      | HTMLSelectElement;

    if (event.target instanceof HTMLButtonElement) {
      target = event.target;
      event.preventDefault();
    } else if (
      event.target instanceof HTMLInputElement ||
      event.target instanceof HTMLTextAreaElement ||
      event.target instanceof HTMLSelectElement
    ) {
      target = event.target;
    } else {
      event.preventDefault();
      // When we click a button which contains another element such as an SVG, the target will be the child element
      if (event.type == 'click') {
        const closestBtn = (event.target as Element).closest('button');
        if (closestBtn == null) {
          console.error(
            'Target must be input or button, got click on non-button',
          );
          console.error(event);
          return;
        }
        target = closestBtn;
      } else {
        console.error('Target must be input or button', event.target);
        console.error(event);
        return;
      }
    }

    if (!target.validity.valid) return;

    // Cancel any existing update request before starting a new one
    this.#activeRequest?.abort();

    const form = target.form as HTMLFormElement;
    const formData = new FormData(form);

    // Add the last changed field
    formData.set('action_initiator_name', target.name);
    formData.delete('_method');

    // Parse existing URL to extract base path and existing query parameters
    const [basePath, existingQuery] = this.#formGetAction.split('?');
    const params = new URLSearchParams(existingQuery || '');

    // Remove any existing params that are overridden by form data, then append all
    // form values. Using append (not set) preserves multi-value fields like material_ids[].
    const formKeys = new Set<string>();
    formData.forEach((value, key) => {
      if (!(value instanceof File)) formKeys.add(key);
    });
    formKeys.forEach((key) => params.delete(key));

    // Add form data to params (will override existing params with same key)
    formData.forEach((value, key) => {
      if (value instanceof File) {
        // It is not possible to do form update with files, therefore we ignore the file values. If you need the
        // file to persist between form updates consider adding 'data-turbo-permanent' to your input.
      } else {
        params.append(key, value.toString());
      }
    });

    const url = `${basePath}?${params.toString()}`;

    this.#activeRequest = new AbortController();

    const turboFrame = form.closest('turbo-frame') as Element;

    try {
      await turboFetch(url, turboFrame, { signal: this.#activeRequest.signal });
    } catch (error) {
      // Don't log errors for aborted requests
      if (error instanceof Error && error.name !== 'AbortError') {
        console.error('Form update failed:', error);
      }
    } finally {
      // Clear the active request when done
      this.#activeRequest = null;
    }
  }

  #handleSubmitStart() {
    // Cancel any outstanding update request
    this.#activeRequest?.abort();
    this.#activeRequest = null;

    this.#toggleSubmitButton(false);
  }

  #handleSubmitEnd(event: any) {
    if (event.detail.success && event.detail.formSubmission.result.success) {
      this.#toggleSubmitButton(false);
    } else {
      this.#toggleSubmitButton(true);
    }
  }

  #toggleSubmitButton(enable: boolean) {
    document
      .querySelectorAll(`[form="${this.element.id}"][type="submit"]`)
      .forEach((btn) => {
        const button = btn as HTMLButtonElement;
        if (enable) {
          button.disabled = false;
          button.style.opacity = '';
        } else {
          button.disabled = true;
          button.style.opacity = '1';
        }
      });
  }
}
