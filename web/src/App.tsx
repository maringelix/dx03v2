import { useEffect, useState } from 'react';
import {
  createMessage,
  deleteMessage,
  describeError,
  getInfo,
  listMessages,
  type ApiInfo,
  type Message,
} from './api.ts';
import { AdminPanel } from './components/AdminPanel.tsx';
import { InfoFooter } from './components/InfoFooter.tsx';
import { MessageForm } from './components/MessageForm.tsx';
import { MessageList } from './components/MessageList.tsx';
import type { MessageDraft } from './validation.ts';

export function App() {
  const [items, setItems] = useState<Message[]>([]);
  const [loading, setLoading] = useState(true);
  const [status, setStatus] = useState('');
  const [error, setError] = useState('');
  const [adminToken, setAdminToken] = useState('');
  const [info, setInfo] = useState<ApiInfo>();
  const [infoFailed, setInfoFailed] = useState(false);

  const announce = (message: string) => {
    setError('');
    setStatus(message);
  };
  const fail = (err: unknown) => {
    setStatus('');
    setError(describeError(err));
  };

  const load = async () => {
    try {
      setItems(await listMessages());
    } catch (err) {
      fail(err);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    let active = true;
    listMessages().then(
      (messages) => {
        if (active) {
          setItems(messages);
          setLoading(false);
        }
      },
      (err: unknown) => {
        if (active) {
          setStatus('');
          setError(describeError(err));
          setLoading(false);
        }
      },
    );
    getInfo().then(
      (value) => {
        if (active) {
          setInfo(value);
        }
      },
      () => {
        if (active) {
          setInfoFailed(true);
        }
      },
    );
    return () => {
      active = false;
    };
  }, []);

  const publish = async (draft: MessageDraft): Promise<boolean> => {
    try {
      const created = await createMessage(draft);
      setItems((current) => [created, ...current]);
      announce('Mensagem publicada.');
      return true;
    } catch (err) {
      fail(err);
      return false;
    }
  };

  const remove = async (message: Message) => {
    try {
      await deleteMessage(message.id, adminToken);
      setItems((current) => current.filter((item) => item.id !== message.id));
      announce(`Mensagem de ${message.author} apagada.`);
    } catch (err) {
      fail(err);
    }
  };

  return (
    <div className="page">
      <header className="masthead">
        <h1>Mural de mensagens</h1>
        <p className="muted">Deixe um recado. As mensagens aparecem da mais nova para a mais antiga.</p>
      </header>

      <main className="content">
        <section className="card" aria-labelledby="form-title">
          <h2 id="form-title">Nova mensagem</h2>
          <MessageForm onSubmit={publish} />
        </section>

        <div className="live-regions">
          <p className="status" role="status">
            {status}
          </p>
          <p className="alert" role="alert">
            {error}
          </p>
        </div>

        <section className="card" aria-labelledby="list-title" aria-busy={loading}>
          <div className="section-header">
            <h2 id="list-title">Mensagens</h2>
            <button
              type="button"
              className="button"
              onClick={() => {
                void load();
              }}
            >
              Atualizar
            </button>
          </div>
          <MessageList
            items={items}
            loading={loading}
            adminMode={adminToken !== ''}
            onDelete={(message) => {
              void remove(message);
            }}
          />
        </section>

        <AdminPanel token={adminToken} onChange={setAdminToken} />
      </main>

      <InfoFooter info={info} failed={infoFailed} />
    </div>
  );
}
