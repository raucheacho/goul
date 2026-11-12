# Le cœur audio de Goul : tests, et les trois artefacts qu'il produit.
#
#     make test      la partie qui compte, sur ta machine (ni appareil, ni réseau)
#     make wasm      -> ../packages/audio-web/assets/goul-audio.wasm
#     make android   -> ../dist/android/arm64-v8a/libgoul-audio.so   (NDK requis)
#     make ios       -> ../dist/ios/GoulAudioCore.xcframework        (macOS + Xcode)
#     make all       les trois
#
# Rien de ce qui est construit n'est commité : la CI le construit à chaque
# version et le publie (voir ../.github/workflows/release.yml).

.PHONY: test wasm android ios all clean

# Le cœur est du calcul pur. Une coupure, une rafale, un livreur coupé en plein
# mot sont reproductibles ici en quelques millisecondes. Puis le module tel que
# le navigateur le charge, et sa compatibilité avec le binaire déjà en service.
test:
	zig build test --summary all
	zig build wasm
	node --test js/

wasm:
	./tools/install-wasm.sh

android:
	./tools/install-android.sh

ios:
	./tools/make-xcframework.sh

# iOS et Android demandent leur SDK ; wasm n'en demande aucun. On ne fait donc
# pas échouer l'ensemble sur une machine qui n'a que l'un des deux.
all: wasm
	@./tools/install-android.sh || echo "  (android ignoré — voir le message ci-dessus)"
	@[ "$$(uname -s)" = "Darwin" ] && ./tools/make-xcframework.sh \
		|| echo "  (ios ignoré — macOS et Xcode requis)"

clean:
	rm -rf zig-out .zig-cache ../dist
