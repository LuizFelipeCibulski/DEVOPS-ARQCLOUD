"""
self-healer - Runbook Automation do ToggleMaster (Fase 4)
=========================================================

Recebe o webhook de alerta do Grafana e executa a ação corretiva do
runbook SEM intervenção humana:

    Grafana (alerta Firing) --POST /webhook/grafana--> self-healer
        -> valida o token (Bearer)
        -> lê os labels do alerta: remediation, namespace, deployment
        -> confere a allowlist e o cooldown
        -> PATCH no Deployment = `kubectl rollout restart`
        -> avisa no Discord ("ação executada")
        -> acompanha o rollout e avisa de novo ("pods novos prontos")

Por que o PATCH e não o binário kubectl: `kubectl rollout restart` nada
mais é que gravar a anotação `kubectl.kubernetes.io/restartedAt` no
template do pod. Mudar o template faz o controller do Deployment criar
um ReplicaSet novo e trocar os pods de forma gradual (rolling update) -
sem downtime. Fazendo direto na API, a imagem não precisa carregar o
kubectl (menos superfície de ataque, menos CVE para o Trivy).

Segurança:
  - O alerta escolhe o ALVO, mas só dentro da allowlist ALLOWED_TARGETS.
    Um label forjado não consegue reiniciar nada fora dela.
  - A ServiceAccount só tem get/patch em deployments, e só nos
    namespaces onde há RoleBinding (ver kubernetes/self-healing/).
  - COOLDOWN_SECONDS impede loop de restart (alert storm / flapping).
"""
import hmac
import json
import logging
import os
import threading
import time
from datetime import datetime, timezone

import requests
from flask import Flask, jsonify, request
from opentelemetry import metrics, trace

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
log = logging.getLogger("self-healer")

# --- Configuração ---------------------------------------------------------
WEBHOOK_TOKEN = os.getenv("SELF_HEALER_TOKEN", "")
DISCORD_WEBHOOK_URL = os.getenv("DISCORD_WEBHOOK_URL", "")
COOLDOWN_SECONDS = int(os.getenv("COOLDOWN_SECONDS", "300"))
ROLLOUT_TIMEOUT_SECONDS = int(os.getenv("ROLLOUT_TIMEOUT_SECONDS", "300"))
# "namespace/deployment,namespace/deployment"
ALLOWED_TARGETS = {t.strip() for t in os.getenv("ALLOWED_TARGETS", "").split(",") if t.strip()}

K8S_API = os.getenv("K8S_API", "https://kubernetes.default.svc")
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"

tracer = trace.get_tracer("self-healer")
meter = metrics.get_meter("self-healer")
actions_counter = meter.create_counter(
    "self_healer_actions",
    description="Ações de self-healing por alvo e resultado",
)

_last_action = {}  # alvo -> epoch da última ação (cooldown)
_lock = threading.Lock()

app = Flask(__name__)


# --- Kubernetes API (sem kubectl) -----------------------------------------
def _k8s_session():
    """ Sessão HTTP autenticada com o token da ServiceAccount do pod. """
    with open(f"{SA_DIR}/token", encoding="utf-8") as f:
        token = f.read().strip()
    s = requests.Session()
    s.headers["Authorization"] = f"Bearer {token}"
    s.verify = f"{SA_DIR}/ca.crt"
    return s


def rollout_restart(namespace, deployment, reason):
    """ Equivalente exato de `kubectl rollout restart deployment/<nome>`. """
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    patch = {"spec": {"template": {"metadata": {"annotations": {
        "kubectl.kubernetes.io/restartedAt": now,
        "self-healer/reason": reason[:250],
    }}}}}
    url = f"{K8S_API}/apis/apps/v1/namespaces/{namespace}/deployments/{deployment}"
    resp = _k8s_session().patch(
        url, data=json.dumps(patch), timeout=10,
        headers={"Content-Type": "application/strategic-merge-patch+json"},
    )
    resp.raise_for_status()
    return resp.json()["metadata"]["generation"]


def wait_rollout(namespace, deployment, generation):
    """ Equivalente a `kubectl rollout status`: espera os pods novos. """
    url = f"{K8S_API}/apis/apps/v1/namespaces/{namespace}/deployments/{deployment}"
    session = _k8s_session()
    deadline = time.time() + ROLLOUT_TIMEOUT_SECONDS
    while time.time() < deadline:
        d = session.get(url, timeout=10).json()
        st, want = d.get("status", {}), d["spec"].get("replicas", 1)
        if (st.get("observedGeneration", 0) >= generation
                and st.get("updatedReplicas", 0) == want
                and st.get("availableReplicas", 0) == want
                and st.get("replicas", 0) == want):
            return True
        time.sleep(5)
    return False


def list_pods(namespace, deployment):
    url = f"{K8S_API}/api/v1/namespaces/{namespace}/pods"
    items = _k8s_session().get(url, params={"labelSelector": f"app={deployment}"}, timeout=10).json().get("items", [])
    return [p["metadata"]["name"] for p in items if p["metadata"].get("deletionTimestamp") is None]


# --- ChatOps --------------------------------------------------------------
def discord(title, description, color):
    """ Mensagem no canal do Discord (embed). Falha aqui nunca derruba a ação. """
    if not DISCORD_WEBHOOK_URL:
        return
    try:
        requests.post(DISCORD_WEBHOOK_URL, timeout=10, json={
            "username": "ToggleMaster Self-Healer",
            "embeds": [{
                "title": title,
                "description": description[:4000],
                "color": color,
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }],
        })
    except requests.RequestException as e:
        log.warning(f"Falha ao notificar o Discord: {e}")


# --- Execução do runbook --------------------------------------------------
def remediate(alert):
    labels = alert.get("labels", {})
    ns, dep = labels.get("namespace", ""), labels.get("deployment", "")
    alertname = labels.get("alertname", "?")
    target = f"{ns}/{dep}"

    if target not in ALLOWED_TARGETS:
        log.warning(f"RECUSADO: {target} fora da allowlist {sorted(ALLOWED_TARGETS)}")
        actions_counter.add(1, {"target": target, "result": "denied"})
        return {"target": target, "result": "denied"}

    with _lock:
        last = _last_action.get(target, 0)
        if time.time() - last < COOLDOWN_SECONDS:
            restante = int(COOLDOWN_SECONDS - (time.time() - last))
            log.info(f"COOLDOWN: {target} reiniciado há pouco; ignorando ({restante}s restantes)")
            actions_counter.add(1, {"target": target, "result": "cooldown"})
            return {"target": target, "result": "cooldown"}
        _last_action[target] = time.time()

    with tracer.start_as_current_span("runbook rollout-restart", attributes={
        "k8s.namespace.name": ns, "k8s.deployment.name": dep, "alert.name": alertname,
    }):
        antes = list_pods(ns, dep)
        log.info(f"SELF-HEALING: alerta '{alertname}' -> kubectl rollout restart deployment/{dep} -n {ns} "
                 f"(pods atuais: {antes})")
        generation = rollout_restart(ns, dep, f"alerta {alertname}")
        actions_counter.add(1, {"target": target, "result": "restarted"})

    discord(
        f"🤖 Self-healing acionado: rollout restart {target}",
        f"**Alerta:** {alertname}\n"
        f"**Resumo:** {alert.get('annotations', {}).get('summary', '-')}\n"
        f"**Ação:** `kubectl rollout restart deployment/{dep} -n {ns}`\n"
        f"**Pods antes:** {', '.join(antes) or '-'}",
        0xF5A623,
    )

    # Acompanha o rollout fora da requisição: o Grafana espera resposta
    # rápida do webhook (timeout), e o rollout leva dezenas de segundos.
    def _acompanha():
        ok = wait_rollout(ns, dep, generation)
        depois = list_pods(ns, dep)
        if ok:
            log.info(f"SELF-HEALING OK: {target} com pods novos e prontos: {depois}")
            discord(f"✅ Rollout concluído: {target}",
                    f"Pods novos prontos: {', '.join(depois)}\n"
                    f"O alerta deve voltar a **Normal** quando a taxa de erro cair.", 0x2ECC71)
        else:
            log.error(f"SELF-HEALING FALHOU: {target} não ficou pronto em {ROLLOUT_TIMEOUT_SECONDS}s")
            discord(f"❌ Rollout NÃO concluiu: {target}",
                    "Escalando para humano: verifique o incidente no PagerDuty.", 0xE74C3C)

    threading.Thread(target=_acompanha, daemon=True).start()
    return {"target": target, "result": "restarted"}


# --- HTTP -----------------------------------------------------------------
@app.route('/health')
def health():
    return jsonify({"status": "ok"})


@app.route('/webhook/grafana', methods=['POST'])
def grafana_webhook():
    auth = request.headers.get("Authorization", "")
    # compare_digest: comparação em tempo constante (evita timing attack)
    if not WEBHOOK_TOKEN or not hmac.compare_digest(auth, f"Bearer {WEBHOOK_TOKEN}"):
        log.warning("Webhook recusado: token inválido")
        return jsonify({"error": "unauthorized"}), 401

    payload = request.get_json(silent=True) or {}
    resultados = []
    for alert in payload.get("alerts", []):
        labels = alert.get("labels", {})
        if alert.get("status") != "firing":
            log.info(f"Alerta '{labels.get('alertname')}' resolvido - nada a fazer.")
            continue
        if labels.get("remediation") != "rollout-restart":
            continue
        try:
            resultados.append(remediate(alert))
        except requests.RequestException as e:
            log.error(f"Falha ao executar o runbook: {e}")
            resultados.append({"target": f"{labels.get('namespace')}/{labels.get('deployment')}", "result": "error"})
    return jsonify({"actions": resultados}), 200


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.getenv("PORT", "8080")), debug=False)
