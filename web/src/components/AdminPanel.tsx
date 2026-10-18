interface Props {
  token: string;
  onChange: (token: string) => void;
}

/** "Admin mode": the token lives only in React state (memory of this tab), never in storage. */
export function AdminPanel({ token, onChange }: Props) {
  return (
    <section className="card" aria-labelledby="admin-title">
      <h2 id="admin-title">Admin mode</h2>
      <p className="muted">
        Paste the admin token to delete messages. It stays only in this tab's memory and disappears when the page
        reloads.
      </p>
      <div className="field">
        <label htmlFor="admin-token">Admin token</label>
        <input
          id="admin-token"
          name="admin-token"
          type="password"
          autoComplete="off"
          spellCheck={false}
          value={token}
          onChange={(event) => {
            onChange(event.target.value.trim());
          }}
        />
      </div>
      {token !== '' && (
        <button
          type="button"
          className="button"
          onClick={() => {
            onChange('');
          }}
        >
          Exit admin mode
        </button>
      )}
    </section>
  );
}
