import type { ApiInfo } from '../api.ts';

interface Props {
  info: ApiInfo | undefined;
  failed: boolean;
}

export function InfoFooter({ info, failed }: Props) {
  let content = 'Carregando informações da API…';
  if (failed) {
    content = 'Informações da API indisponíveis.';
  } else if (info !== undefined) {
    const commit = /^[0-9a-f]{7,40}$/.test(info.commit) ? info.commit.slice(0, 7) : info.commit;
    content = `API ${info.version} · commit ${commit} · ambiente ${info.environment}`;
  }
  return (
    <footer className="footer">
      <p>{content}</p>
      <p className="muted">dx03v2 · lab educacional · código aberto (MIT)</p>
    </footer>
  );
}
