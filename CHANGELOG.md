# Journal des changements

## 1.0.1

Documentation publique en anglais (page npm, README du dépôt, notes de
version), comme konet. Aucun changement de code.

## 1.0.0

Première version publiée depuis ce dépôt. Le cœur est celui que Goul, Livro et
Phono embarquaient chacun en copie (`0.1.0`), sans changement de comportement :

- les trames émises et le son joué sont identiques au bit près à ceux du
  binaire `0.1.0` (`core/js/compat.test.mjs`) ;
- porté sur Zig 0.17.1 (`@cImport` remplacé par une traduction dans le build) ;
- les binaires ne sont plus commités chez les apps : la CI les construit et les
  publie à chaque version.
