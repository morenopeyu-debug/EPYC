/* =====================================================================
   99_reset.sql
   Borra TODO el esquema dbo de la base donde se ejecute.

   ⚠  DESTRUCTIVO. Se lleva tablas, datos, vistas, funciones y trigger.
      Úsalo sólo si quieres reinstalar desde cero, y asegúrate de estar
      conectado a la base correcta.

   Después de correrlo, vuelve a ejecutar 01 -> 02 -> 03 -> 04 (-> 05).
   ===================================================================== */

DROP SCHEMA IF EXISTS dbo CASCADE;

DO $$ BEGIN
    RAISE NOTICE 'Esquema dbo eliminado. Vuelve a correr 01_esquema.sql.';
END $$;
