import { describe, expect, it } from 'vitest';
import { setupAttachmentSelection } from '../shared/dom';

const setup = () => {
  document.body.innerHTML = `
    <button data-select-page type="button">Select page</button>
    <form id="attachment-download-form"></form>
    <form id="attachment-paperless-form"></form>
    <article data-attachment-row data-attachment-key="first" tabindex="0"></article>
    <article data-attachment-row data-attachment-key="second" tabindex="0"><button type="button">Inner</button></article>
  `;
  return setupAttachmentSelection(document);
};

describe('attachment selection island helpers', () => {
  it('toggles row selection and syncs hidden bulk form inputs', () => {
    const cleanup = setup();
    document.querySelector<HTMLElement>('[data-attachment-key="first"]')?.click();

    expect(document.querySelector('[data-attachment-key="first"]')?.getAttribute('aria-selected')).toBe('true');
    expect(Array.from(document.querySelectorAll<HTMLInputElement>('#attachment-download-form input[name="attachment_keys"]')).map((input) => input.value)).toEqual(['first']);
    expect(Array.from(document.querySelectorAll<HTMLInputElement>('#attachment-paperless-form input[name="attachment_keys"]')).map((input) => input.value)).toEqual(['first']);
    cleanup();
  });

  it('selects every visible row with select page', () => {
    const cleanup = setup();
    document.querySelector<HTMLElement>('[data-select-page]')?.click();

    expect(Array.from(document.querySelectorAll<HTMLInputElement>('#attachment-download-form input[name="attachment_keys"]')).map((input) => input.value)).toEqual(['first', 'second']);
    cleanup();
  });

  it('ignores clicks on interactive children', () => {
    const cleanup = setup();
    document.querySelector<HTMLButtonElement>('[data-attachment-key="second"] button')?.click();

    expect(document.querySelector('[data-attachment-key="second"]')?.getAttribute('aria-selected')).toBe('false');
    expect(document.querySelectorAll('#attachment-download-form input[name="attachment_keys"]')).toHaveLength(0);
    cleanup();
  });

  it('supports keyboard activation', () => {
    const cleanup = setup();
    document.querySelector<HTMLElement>('[data-attachment-key="second"]')?.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));

    expect(document.querySelector('[data-attachment-key="second"]')?.getAttribute('aria-selected')).toBe('true');
    cleanup();
  });
});
