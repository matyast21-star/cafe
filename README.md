# Cafetería Magnolias

Sitio web de Cafetería Magnolias (Casablanca, Chile). Es un sitio estático: `index.html` + carpeta `media/`.

- **Club Magnolias (tarjeta de sellos):** usa Supabase (proyecto `qspqdtxqybozrkgddezt`). El esquema está en `supabase/club_magnolias_schema.sql`.
- **Panel del barista:** dirección del sitio + `#caja` (ingreso con correo y contraseña del equipo).
- **Publicar:** Cloudflare (Workers & Pages) conectado a este repositorio, sin comando de build y con la raíz del repositorio como carpeta de salida.

Sitio creado por fluva.

## App en el teléfono
`manifest.webmanifest`, `sw.js` e `icons/` permiten agregar la tarjeta a la pantalla de inicio (abre directo en `#club`).
Si cambias imágenes o íconos con el mismo nombre, sube la versión de `CACHE` en `sw.js` para que los teléfonos descarguen la nueva.
