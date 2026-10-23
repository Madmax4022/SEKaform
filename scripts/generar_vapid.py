"""Genera las llaves VAPID para los avisos push. Se corre UNA vez por entorno.

    python3 scripts/generar_vapid.py

Imprime la llave pública (va en infra/cliente.tfvars como `vapid_publica`) y el
comando para guardar la privada en Secret Manager. La privada no se escribe en
ningún archivo. Si se pierde o se cambia, los celulares deben volver a activar
los avisos.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from app.push import generar_claves  # noqa: E402

pub, priv = generar_claves()
print("1) En infra/cliente.tfvars:\n")
print(f'   habilitar_push = true\n   vapid_publica  = "{pub}"\n')
print("2) Guarda la llave privada en Secret Manager (no la copies en ningún archivo):\n")
print(f"   echo -n '{priv}' | gcloud secrets versions add skf-vapid-private-key --data-file=-\n")
print("3) cd infra && terraform apply -var-file=cliente.tfvars")
