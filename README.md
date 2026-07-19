# My Omarchy Config

Este repositorio contiene mi configuración personalizada de Omarchy, paquetes opcionales y gestión segura de secretos mediante AWS SSM Parameter Store.

## Estructura del Proyecto

*   `dotfiles/`: Contiene los archivos de configuración locales que se enlazarán en `~/.config/`.
*   `terraform/`: Código de Terraform para declarar y aprovisionar secretos en AWS SSM Parameter Store.
*   `install.sh`: Script interactivo (wizard) para importar configuraciones, instalar paquetes y aplicar enlaces.

## Configuración de Secretos (AWS SSM)

Para evitar subir secretos en texto plano a Git, usamos AWS SSM Parameter Store.

1.  Copia el ejemplo de variables en la carpeta `terraform/`:
    ```bash
    cp terraform/terraform.tfvars.example terraform/terraform.tfvars
    ```
2.  Edita `terraform/terraform.tfvars` con tus secretos reales (este archivo está ignorado en Git).
3.  Inicializa y aplica la configuración en AWS:
    ```bash
    cd terraform
    terraform init
    terraform apply
    ```
4.  Crea un archivo terminado en `.template` en `dotfiles/` (ej. `dotfiles/gentle-ai/config.json.template`).
5.  Usa el marcador `{{SSM:ruta/del/secreto}}` para referenciar la clave definida en Terraform. El script `install.sh` se encargará de resolver el secreto y generar el archivo final en caliente sin comprometer el repositorio.

## Uso del Script de Instalación

### Importar configuraciones locales al repositorio (inicial)
```bash
./install.sh --import
```

### Ejecutar el asistente de instalación y configuración
```bash
./install.sh --install
```
