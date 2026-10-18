import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it } from 'vitest';
import { App } from '../App.tsx';
import type { Message } from '../api.ts';
import { apiError, INFO, json, mockFetch, type FetchCall } from './fetch.ts';

const TOKEN = 'admin-token-0123456789abcdef0123456789abcdef';

const ana: Message = { id: 2, author: 'Ana', text: 'Olá, mural!', createdAt: '2026-10-10T12:00:00.000Z' };
const bia: Message = { id: 1, author: 'Bia', text: '<b>sem negrito</b>', createdAt: '2026-10-10T11:00:00.000Z' };

/** Default API: GET list + info; `extra` handles everything else. */
function api(items: Message[], extra?: (call: FetchCall) => Response | undefined) {
  return mockFetch((call) => {
    const handled = extra?.(call);
    if (handled !== undefined) {
      return handled;
    }
    if (call.method === 'GET' && call.url.startsWith('/api/messages')) {
      return json(200, { items });
    }
    if (call.method === 'GET' && call.url === '/api/info') {
      return json(200, INFO);
    }
    return apiError(404, 'not_found', 'Route not found');
  });
}

async function renderApp() {
  render(<App />);
  await screen.findByText(/API 2\.0\.0/);
}

describe('App', () => {
  it('lists messages newest first and shows build info in the footer', async () => {
    api([ana, bia]);
    await renderApp();
    const items = await screen.findAllByRole('listitem');
    expect(items).toHaveLength(2);
    expect(within(items[0]!).getByText('Ana')).toBeInTheDocument();
    expect(within(items[1]!).getByText('Bia')).toBeInTheDocument();
    const englishDate = new Intl.DateTimeFormat('en-US', { dateStyle: 'short', timeStyle: 'short' });
    expect(within(items[0]!).getByText(englishDate.format(new Date(ana.createdAt)))).toBeInTheDocument();
    expect(screen.getByText('API 2.0.0 · commit 0123456 · environment kind')).toBeInTheDocument();
  });

  it('renders stored markup as plain text', async () => {
    api([bia]);
    await renderApp();
    const text = await screen.findByText('<b>sem negrito</b>');
    expect(text.tagName).toBe('P');
    expect(text.querySelector('b')).toBeNull();
  });

  it('shows an empty state', async () => {
    api([]);
    await renderApp();
    expect(await screen.findByText(/No messages yet/)).toBeInTheDocument();
  });

  it('publishes a message and announces it', async () => {
    const user = userEvent.setup();
    const created: Message = { id: 3, author: 'Caio', text: 'Nova', createdAt: '2026-10-10T13:00:00.000Z' };
    const calls = api([ana], (call) => (call.method === 'POST' ? json(201, created) : undefined));
    await renderApp();

    await user.type(screen.getByLabelText('Your name'), '  Caio ');
    await user.type(screen.getByLabelText('Message'), 'Nova');
    await user.click(screen.getByRole('button', { name: 'Publish' }));

    expect(await screen.findByRole('status')).toHaveTextContent('Message published.');
    const post = calls.find((call) => call.method === 'POST');
    expect(post).toMatchObject({
      url: '/api/messages',
      headers: { 'content-type': 'application/json' },
      body: { author: 'Caio', text: 'Nova' },
    });
    const items = screen.getAllByRole('listitem');
    expect(within(items[0]!).getByText('Caio')).toBeInTheDocument();
    expect(screen.getByLabelText('Your name')).toHaveValue('');
    expect(screen.getByLabelText('Message')).toHaveValue('');
  });

  it('shows API errors in an alert and keeps the draft', async () => {
    const user = userEvent.setup();
    api([], (call) =>
      call.method === 'POST' ? apiError(429, 'rate_limited', 'Too many write requests', 'req-429') : undefined,
    );
    await renderApp();

    await user.type(screen.getByLabelText('Your name'), 'Ana');
    await user.type(screen.getByLabelText('Message'), 'de novo');
    await user.click(screen.getByRole('button', { name: 'Publish' }));

    expect(await screen.findByRole('alert')).toHaveTextContent(
      'Too many messages. Wait a minute and try again. (request ID: req-429)',
    );
    expect(screen.getByLabelText('Message')).toHaveValue('de novo');
    expect(screen.getByRole('status')).toHaveTextContent('');
  });

  it('validates on the client with the API limits before sending', async () => {
    const user = userEvent.setup();
    const calls = api([]);
    await renderApp();

    await user.click(screen.getByRole('button', { name: 'Publish' }));
    const author = screen.getByLabelText('Your name');
    expect(author).toHaveAttribute('aria-invalid', 'true');
    expect(author).toHaveAccessibleDescription(/1 to 40 characters.*Required field\./);
    expect(screen.getByLabelText('Message')).toHaveAccessibleDescription(/Required field\./);

    await user.type(author, 'a'.repeat(41));
    await user.type(screen.getByLabelText('Message'), 'tab{Tab}');
    await user.click(screen.getByRole('button', { name: 'Publish' }));
    expect(screen.getByText('Use at most 40 characters (current: 41).')).toBeInTheDocument();
    expect(calls.some((call) => call.method === 'POST')).toBe(false);
  });

  it('rejects control characters', async () => {
    const user = userEvent.setup();
    api([]);
    await renderApp();
    await user.type(screen.getByLabelText('Your name'), 'Ana');
    // user-event cannot type a raw control character; paste one instead.
    await user.click(screen.getByLabelText('Message'));
    await user.paste('linha\u0007sino');
    await user.click(screen.getByRole('button', { name: 'Publish' }));
    expect(screen.getByText('Do not use control characters (such as tabs).')).toBeInTheDocument();
  });

  it('only offers deletion in admin mode and sends the bearer token', async () => {
    const user = userEvent.setup();
    const calls = api([ana, bia], (call) => (call.method === 'DELETE' ? json(204, null) : undefined));
    await renderApp();
    await screen.findByText('Olá, mural!');
    expect(screen.queryByRole('button', { name: /Delete/ })).toBeNull();

    await user.type(screen.getByLabelText('Admin token'), TOKEN);
    await user.click(screen.getByRole('button', { name: 'Delete message by Ana' }));

    expect(await screen.findByRole('status')).toHaveTextContent('Message by Ana deleted.');
    expect(screen.queryByText('Olá, mural!')).toBeNull();
    const del = calls.find((call) => call.method === 'DELETE');
    expect(del).toMatchObject({ url: '/api/messages/2', headers: { authorization: `Bearer ${TOKEN}` } });

    await user.click(screen.getByRole('button', { name: 'Exit admin mode' }));
    expect(screen.queryByRole('button', { name: /Delete/ })).toBeNull();
    expect(screen.getByLabelText('Admin token')).toHaveValue('');
  });

  it('explains a rejected admin token', async () => {
    const user = userEvent.setup();
    api([ana], (call) =>
      call.method === 'DELETE' ? apiError(401, 'unauthorized', 'A valid admin token is required') : undefined,
    );
    await renderApp();
    await user.type(screen.getByLabelText('Admin token'), 'wrong-token');
    await user.click(await screen.findByRole('button', { name: 'Delete message by Ana' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('Invalid admin token.');
    expect(screen.getByText('Olá, mural!')).toBeInTheDocument();
  });

  it('reports an unreachable API and recovers with "Refresh"', async () => {
    const user = userEvent.setup();
    let online = false;
    mockFetch((call) => {
      if (!online) {
        throw new TypeError('Failed to fetch');
      }
      return call.url === '/api/info' ? json(200, INFO) : json(200, { items: [ana] });
    });
    render(<App />);
    expect(await screen.findByRole('alert')).toHaveTextContent('Could not reach the API.');
    expect(await screen.findByText('API information is unavailable.')).toBeInTheDocument();

    online = true;
    await user.click(screen.getByRole('button', { name: 'Refresh' }));
    await waitFor(() => {
      expect(screen.getByText('Olá, mural!')).toBeInTheDocument();
    });
  });
});
