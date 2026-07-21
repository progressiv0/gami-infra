-- ArgoCD's built-in Ingress health check expects .status.loadBalancer.ingress
-- to be populated (an IP/hostname a cloud LoadBalancer would assign). This
-- k3s cluster runs Traefik with servicelb disabled (see
-- ansible/roles/k3s-server/defaults/main.yml — Traefik handles ingress
-- directly on the host network instead), so that field is never populated
-- for ANY Ingress here, in local testing or real production alike.
-- Confirmed against a real cluster: every sync got stuck forever on
-- "waiting for healthy state of networking.k8s.io/Ingress/..." because of
-- this exact mismatch — not a one-off local quirk.
--
-- Once an Ingress is created (spec exists), treat it as Healthy — Traefik's
-- own routing correctness is verified by actually hitting the hostnames,
-- not by ArgoCD's loadBalancer-status heuristic, which doesn't apply here.
hs = {}
hs.status = "Healthy"
hs.message = "Ingress is considered healthy once created (Traefik host-network mode never populates status.loadBalancer)"
return hs
