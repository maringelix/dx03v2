interface Props {
  token: string;
  onChange: (token: string) => void;
}

/** "Modo admin": the token lives only in React state (memory of this tab), never in storage. */
export function AdminPanel({ token, onChange }: Props) {
  return (
    <section className="card" aria-labelledby="admin-title">
      <h2 id="admin-title">Modo admin</h2>
      <p className="muted">
        Cole o token de administração para poder apagar mensagens. Ele fica apenas na memória desta aba e some ao
        recarregar a página.
      </p>
      <div className="field">
        <label htmlFor="admin-token">Token de admin</label>
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
          Sair do modo admin
        </button>
      )}
    </section>
  );
}
