#!/usr/bin/env python3
"""
Gera kubernetes/observability/config/dashboard-togglemaster.yaml

O dashboard é código: este script monta o JSON do Grafana e embrulha num
ConfigMap com o label grafana_dashboard: "1" (lido pelo sidecar do
Grafana). Mudou um painel? Edite aqui, rode, commite - o Argo CD aplica.

    python3 techchallange4/scripts/gerar-dashboard.py

Três blocos, exatamente o que o desafio pede:
  1. Saúde do cluster ......... CPU/memória dos nós e dos serviços, réplicas
  2. Microsserviços (RED) ..... requisições/s, % de erro, latência p95
  3. Logs em tempo real ....... Loki, filtrável por serviço e texto
"""
import json
import os

PROM = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}
APPS = '(auth|flag|targeting|evaluation|analytics)-service'
SERVER = 'span_kind="SPAN_KIND_SERVER"'

_id = 0


def nid():
    global _id
    _id += 1
    return _id


def row(title, y):
    return {"type": "row", "title": title, "id": nid(), "collapsed": False,
            "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": []}


def stat(title, expr, x, y, w=4, h=4, unit="percentunit", thresholds=None, desc=""):
    return {
        "type": "stat", "title": title, "id": nid(), "description": desc, "datasource": PROM,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": [{"refId": "A", "expr": expr, "datasource": PROM}],
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background", "graphMode": "area"},
        "fieldConfig": {"defaults": {"unit": unit, "decimals": 1, "thresholds": thresholds or {
            "mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 0.7},
                                          {"color": "red", "value": 0.85}]}}, "overrides": []},
    }


def ts(title, targets, x, y, w=12, h=8, unit="short", desc="", stack=False, thresholds=None):
    defaults = {"unit": unit, "custom": {"lineWidth": 2, "fillOpacity": 15,
                                         "stacking": {"mode": "normal" if stack else "none"}}}
    if thresholds:
        defaults["thresholds"] = thresholds
        defaults["custom"]["thresholdsStyle"] = {"mode": "line+area"}
    return {
        "type": "timeseries", "title": title, "id": nid(), "description": desc, "datasource": PROM,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": [{"refId": chr(65 + i), "expr": e, "legendFormat": l, "datasource": PROM}
                    for i, (e, l) in enumerate(targets)],
        "options": {"legend": {"displayMode": "table", "placement": "right", "calcs": ["lastNotNull", "max"]},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
        "fieldConfig": {"defaults": defaults, "overrides": []},
    }


panels = []
y = 0

# ---------------------------------------------------------------- 1. Cluster
panels.append(row("☸️ Saúde do cluster EKS", y)); y += 1
panels += [
    stat("CPU do cluster", '1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))', 0, y,
         desc="Uso médio de CPU de todos os nós (node-exporter)."),
    stat("Memória do cluster", '1 - sum(node_memory_MemAvailable_bytes) / sum(node_memory_MemTotal_bytes)', 4, y,
         desc="Memória em uso somando todos os nós."),
    stat("Nós prontos", 'sum(kube_node_status_condition{condition="Ready",status="true"})', 8, y, unit="none",
         thresholds={"mode": "absolute", "steps": [{"color": "red", "value": None}, {"color": "green", "value": 2}]}),
    stat("Pods dos microsserviços", f'sum(kube_pod_status_phase{{namespace=~"{APPS}",phase="Running"}})', 12, y,
         unit="none", thresholds={"mode": "absolute", "steps": [{"color": "blue", "value": None}]}),
    stat("Restarts (1h)", f'sum(increase(kube_pod_container_status_restarts_total{{namespace=~"{APPS}"}}[1h]))',
         16, y, unit="none", thresholds={"mode": "absolute", "steps": [
             {"color": "green", "value": None}, {"color": "orange", "value": 1}, {"color": "red", "value": 5}]},
         desc="Restarts de container: inclui os rollout restart do self-healer."),
    stat("Self-healing (24h)", 'sum(increase(self_healer_actions_total{result="restarted"}[24h])) or vector(0)',
         20, y, unit="none", thresholds={"mode": "absolute", "steps": [
             {"color": "green", "value": None}, {"color": "purple", "value": 1}]},
         desc="Quantas vezes a automação executou rollout restart."),
]
y += 4
panels += [
    ts("CPU por microsserviço (cores)",
       [(f'sum by (namespace) (rate(container_cpu_usage_seconds_total{{namespace=~"{APPS}",container!=""}}[5m]))',
         "{{namespace}}")], 0, y, w=8, unit="none"),
    ts("Memória por microsserviço",
       [(f'sum by (namespace) (container_memory_working_set_bytes{{namespace=~"{APPS}",container!=""}})',
         "{{namespace}}")], 8, y, w=8, unit="bytes"),
    ts("Réplicas disponíveis (HPA / KEDA)",
       [(f'kube_deployment_status_replicas_available{{namespace=~"{APPS}"}}', "{{deployment}}")],
       16, y, w=8, unit="none",
       desc="Mostra o HPA do evaluation e o scale-to-zero do analytics (KEDA) - e o rollout do self-healer."),
]
y += 8

# ---------------------------------------------------------- 2. RED (OTel)
panels.append(row("🚦 Microsserviços - RED (via OpenTelemetry spanmetrics)", y)); y += 1
panels += [
    ts("Requisições por segundo",
       [(f'sum by (service_name) (rate(traces_span_metrics_calls_total{{{SERVER}}}[1m]))', "{{service_name}}")],
       0, y, w=12, unit="reqps",
       desc="Taxa de requisições (spans SERVER) por serviço. Métrica gerada pelo connector spanmetrics do OTel Collector."),
    ts("Taxa de erro (5xx)",
       [(f'(sum by (service_name) (rate(traces_span_metrics_calls_total{{{SERVER},http_response_status_code=~"5.."}}[2m])) '
         f'/ sum by (service_name) (rate(traces_span_metrics_calls_total{{{SERVER}}}[2m])))', "{{service_name}}")],
       12, y, w=12, unit="percentunit",
       thresholds={"mode": "absolute", "steps": [{"color": "transparent", "value": None}, {"color": "red", "value": 0.05}]},
       desc="Linha vermelha = 5%, o limite do alerta do auth-service."),
]
y += 8
panels += [
    ts("Latência p95",
       [(f'histogram_quantile(0.95, sum by (le, service_name) (rate(traces_span_metrics_duration_seconds_bucket{{{SERVER}}}[5m])))',
         "{{service_name}}")], 0, y, w=12, unit="s"),
    ts("Respostas por status HTTP",
       [(f'sum by (service_name, http_response_status_code) (rate(traces_span_metrics_calls_total{{{SERVER}}}[1m]))',
         "{{service_name}} {{http_response_status_code}}")], 12, y, w=12, unit="reqps", stack=True),
]
y += 8
panels.append(
    stat("auth-service: % de 5xx agora",
         f'(sum(rate(traces_span_metrics_calls_total{{service_name="auth-service",{SERVER},http_response_status_code=~"5.."}}[2m])) or vector(0))'
         f' / sum(rate(traces_span_metrics_calls_total{{service_name="auth-service",{SERVER}}}[2m]))',
         0, y, w=6, h=6, thresholds={"mode": "absolute", "steps": [{"color": "green", "value": None},
                                                                   {"color": "red", "value": 0.05}]},
         desc="Mesma expressão do alerta 'auth-service - taxa de erros 5xx acima de 5%'."))
panels.append(
    ts("Mensagens na fila SQS / eventos processados",
       [('sum by (service_name) (rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_PRODUCER"}[1m]))', "publicadas ({{service_name}})"),
        ('sum by (service_name) (rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_CONSUMER"}[1m]))', "consumidas ({{service_name}})")],
       6, y, w=18, h=6, unit="reqps",
       desc="Spans PRODUCER (evaluation) x CONSUMER (analytics): o trace atravessa a fila."))
y += 6

# ----------------------------------------------------------------- 3. Logs
panels.append(row("📜 Logs em tempo real (Loki)", y)); y += 1
panels.append({
    "type": "timeseries", "title": "Linhas de log com erro por serviço", "id": nid(), "datasource": LOKI,
    "gridPos": {"h": 6, "w": 24, "x": 0, "y": y},
    "targets": [{"refId": "A", "datasource": LOKI, "legendFormat": "{{service_name}}",
                 "expr": 'sum by (service_name) (count_over_time({k8s_namespace_name=~"$namespace"} |~ "(?i)(erro|error|exception|traceback)" [1m]))'}],
    "fieldConfig": {"defaults": {"unit": "short", "custom": {"drawStyle": "bars", "fillOpacity": 60}}, "overrides": []},
    "options": {"legend": {"displayMode": "list", "placement": "bottom"}},
})
y += 6
panels.append({
    "type": "logs", "title": "Logs dos containers (filtre por namespace e texto no topo)", "id": nid(),
    "datasource": LOKI, "gridPos": {"h": 14, "w": 24, "x": 0, "y": y},
    "targets": [{"refId": "A", "datasource": LOKI,
                 "expr": '{k8s_namespace_name=~"$namespace"} |~ "(?i)$busca"'}],
    "options": {"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending",
                "enableLogDetails": True, "dedupStrategy": "none", "prettifyLogMessage": False},
})

dashboard = {
    "uid": "togglemaster-saude",
    "title": "ToggleMaster - Saúde do Ecossistema",
    "description": "Cluster, microsserviços (RED via OpenTelemetry) e logs em tempo real - Tech Challenge Fase 4",
    "tags": ["togglemaster", "fase4", "opentelemetry"],
    "timezone": "browser", "editable": True, "refresh": "10s", "schemaVersion": 39,
    "time": {"from": "now-30m", "to": "now"},
    "templating": {"list": [
        {"name": "namespace", "label": "Namespace", "type": "custom", "multi": True, "includeAll": True,
         "allValue": f"{APPS}|self-healing|observability",
         "query": "auth-service,flag-service,targeting-service,evaluation-service,analytics-service,self-healing,observability",
         "current": {"selected": True, "text": ["All"], "value": ["$__all"]}},
        {"name": "busca", "label": "Texto no log (regex)", "type": "textbox", "query": "",
         "current": {"text": "", "value": ""}},
    ]},
    "panels": panels,
}

header = '''# =====================================================================
# GERADO por techchallange4/scripts/gerar-dashboard.py - não edite à mão.
# ---------------------------------------------------------------------
# O label grafana_dashboard: "1" faz o sidecar do Grafana carregar este
# JSON como dashboard (pasta "ToggleMaster"), sem clique nenhum.
# =====================================================================
'''
cm = {
    "apiVersion": "v1", "kind": "ConfigMap",
    "metadata": {"name": "dashboard-togglemaster", "namespace": "observability",
                 "labels": {"grafana_dashboard": "1"}, "annotations": {"grafana_folder": "ToggleMaster"}},
    "data": {"togglemaster-saude.json": json.dumps(dashboard, ensure_ascii=False, indent=2)},
}

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "kubernetes", "observability", "config",
                   "dashboard-togglemaster.yaml")
try:
    import yaml  # noqa: E402

    class _Lit(str):
        pass

    yaml.add_representer(_Lit, lambda d, v: d.represent_scalar("tag:yaml.org,2002:str", v, style="|"))
    cm["data"]["togglemaster-saude.json"] = _Lit(cm["data"]["togglemaster-saude.json"])
    body = yaml.dump(cm, allow_unicode=True, sort_keys=False, width=10_000)
except ImportError:
    body = json.dumps(cm, ensure_ascii=False, indent=2)
with open(out, "w", encoding="utf-8") as f:
    f.write(header + body)
print(f"ok: {os.path.normpath(out)} ({len(panels)} painéis)")
