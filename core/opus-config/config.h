/* Réponses du configure d'autotools, figées.
 *
 * libopus s'attend à un config.h généré par autotools. On ne lance pas
 * autotools : Zig compile les sources directement, et les réponses sont les
 * mêmes pour les trois cibles (Android, iOS, WebAssembly). Les écrire ici
 * rend le build reproductible et lisible — plutôt qu'un fichier de 400
 * lignes dont personne ne sait ce qui est réellement utilisé.
 *
 * Tout ce qui touche à la sélection d'instructions SIMD est désactivé : les
 * variantes x86/NEON sont choisies par le configure qu'on n'exécute pas, et
 * le C générique qu'elles remplacent est déjà compilé.
 */

#ifndef GOUL_OPUS_CONFIG_H
#define GOUL_OPUS_CONFIG_H

#define OPUS_BUILD 1
#define PACKAGE_VERSION "1.5.2"

/* Le point fixe est imposé dans build.zig ; répété ici car certains en-têtes
   d'opus regardent config.h avant les -D de la ligne de commande. */
#ifndef FIXED_POINT
#define FIXED_POINT 1
#endif

/* Pas de détection d'instructions à l'exécution. */
#define OPUS_HAVE_RTCD 0

/* Tableaux de taille variable pour le scratch du codec, plutôt qu'une pile
   globale qui ne serait pas sûre entre le thread de capture et celui de
   lecture. */
#define VAR_ARRAYS 1

/* Fonctions C99 présentes sur les trois cibles. */
#define HAVE_LRINTF 1
#define HAVE_LRINT 1

#endif /* GOUL_OPUS_CONFIG_H */
