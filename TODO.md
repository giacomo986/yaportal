# TODO — Luanti Portal

Legenda stato: ✅ fatto · 🟡 parziale · ❌ da fare
Legenda costo: 🟢 Lua puro · 🔴 richiede patch C++ engine (rebuild AppImage, vedi AGENTS.MD)

---

## Funzionalità completate

### ✅ 1. Portali orizzontali
Piani di teletrasporto orizzontali (pavimento/soffitto) oltre a quelli verticali.
Geometria estesa con `axis==2` (anello in XZ a `y=cy`). Trigger su apertura
gestito da `over_floor_opening()` + `floor_portal_cb_shift` (collision-box shift
lato C++).

### ✅ 2. Teletrasporto di entità
Mob ed entità Lua teletrasportati oltre al giocatore. `register_globalstep`
con `entity_states` keyed by `tostring(obj)`, filtro `should_teleport_entity()`
(salta anchor/`_portal_exempt`), cooldown 1.0s post-teleport.

### ✅ 4. Rotazione da portale orizzontale a verticale
Rotazione di velocità/orientamento su traversata H↔V. `portal_transform_dir`
con basi `src_u`/`dst_u` esplicite, pitch via `setLookPitch` (C++), animazione
camera-roll `new_roll → 0` per ogni mismatch di base. Fallback yaw per look
quasi-verticale (gimbal lock).

---

## Extra implementato (fuori dal piano originale)

Funzioni aggiunte non previste in questa lista, già operative:

- **Portal gun** (`portal_gun`, `portal_gun3` type-2, `portal_gun4` in-wall su
  blocco bianco craftabile).
  - **Wall gun — posizionamento pavimento:** direzione = direzione ortogonale più
    vicina alla vista (asse + segno); il blocco puntato è l'estremo *vicino* e il
    portale si estende un blocco in avanti (lontano dal player). Se quel secondo
    blocco non può formare il portale, fallback sul lato opposto (il blocco puntato
    diventa l'estremo lontano).
  - **Wall gun — portale chiuso se non accoppiato:** variante nodo `_off` (gruppo
    `portal_closed`) → blocco solido con sola cornice colorata, niente foro
    trasparente né passthrough pavimento (gated su `pp.link`); si apre solo quando
    linkato. Swap open↔closed via `pgun4_apply_state` su shoot/remove.
- **Portali type-2** = blocchi cavi (`portal_block`, gruppo `portal_block`,
  solidità direzionale lato engine). Tool `portal_gun3`.
- **Exit step-up**: i piedi che atterrano in un blocco solido vengono alzati sopra
  + warp camera (solo traslazione) su lift forzato.
- **Camera roll/pitch** animati con API debug (`/roll`, `/upright`).
- **Colori cielo accurati** attraverso il portale (tramonto/notte/void).
- **Stivali antifall** (slot armor VoxeLibre).

---

## Funzionalità future

### ❌ 3. Sezione di entità attraverso il piano portale  · 🔴 Difficile
Per entità troppo grandi per stare interamente da un lato: rendering e fisica
della parte "dentro" il portale separata dalla parte esterna. Richiede clipping
della mesh dell'entità sul piano del portale.
**Fattibilità:** alta complessità. Serve: estendere `PortalClipPlanes data[20]`→`[24]`,
rilevamento C++ dell'AABB entità che attraversa il piano (`portal.cpp`), render
entità con clip-near in scena principale + clip-far trasformata in RTT. Tutto C++,
rebuild AppImage. È il prossimo candidato naturale (infrastruttura clip-plane già
esiste). Senza questo, le entità a cavallo appaiono come "blob" intero (vedi BUG-1).

### ❌ 5. Attrazione di oggetti attraverso il portale (Gravity Funnel)  · 🟢 Media
L'ingresso si comporta come un buco nero: oggetti lanciati/tirati dal lato di
uscita attratti verso il centro, accumulati un istante sulla superficie, poi passano.
**Fattibilità:** media, fattibile in Lua puro. Riusa il `register_globalstep` entità
già presente: aggiungere campo di forza verso il centro portale per entità item
entro un raggio. Rischio: tuning fisica (oscillazioni), interazione col cooldown
teleport. Nessuna patch C++.

### ❌ 6. Ricarica con energia (Portale energetico)  · 🟢 Facile
I portali consumano "carica" e si spengono dopo un uso/tempo; ricarica con oggetto
speciale o lenta auto-ricarica.
**Fattibilità:** facile, Lua puro. Aggiungere campo `charge` al portal struct,
decremento su teleport/tempo, `close_portal` a zero. Solo bilanciamento di gioco.

### ❌ 7. Portali permanenti vs effimeri  · 🟢 Facile
Portali permanenti vs effimeri (N usi / durata). In alternativa "madre"
(permanente) ↔ "figlio" (effimero).
**Fattibilità:** facile, Lua puro. Sovrappone all'item 6 (contatore usi/timer).
Attualmente i portali sono permanenti (legati al frame/blocco). Aggiungere flag
+ deregistrazione a scadenza.

### 🟡 8. Effetti visivi avanzati
*   ✅ **Rendering del piano attraverso:** pipeline RTT già completa
    (`PortalPrepareStep`/`PortalQuadStep`, virtual camera + clip planes). Core feature.
*   ❌ **Distorsione ottica/frattura** ai bordi · 🔴 — shader/post-process, C++.
*   ❌ **Fumo/nebbia** che attraversa il portale · 🟢 — particelle Lua, facile.
*   ❌ **Raggio guida (laser)** dal centro portale · 🟢 — raycast + entità/particelle Lua, facile.
**Fattibilità:** i sotto-punti Lua (fumo, laser) sono facili. La distorsione bordi
richiede lavoro shader C++.

### ❌ 9. Configurazioni di portali preimpostate  · 🟢 Facile
Salvare/caricare configurazioni (posizione, rotazione, dimensione) per ricrearle
o condividerle.
**Fattibilità:** facile, Lua puro. Serializzazione del portal struct su
`mod_storage` o file; comando load/save. Nessun rischio rendering.

### ❌ 10. Supporto coordinate non cartesiane (Wormholes)  · 🔴 Molto difficile
Wormhole tra punti arbitrari, rotazione completa di orientamento e gravità.
**Fattibilità:** molto alta complessità. La gravità arbitraria non è supportata
dall'engine senza patch profonde (`physics_override` ha solo gravità scalare).
La pipeline RTT regge già coppie arbitrarie, ma orientamento/gravità full-6DOF è
un grosso lavoro C++. Bassa priorità.

### ❌ 11. Integrazione con tunneling/scavo  · 🔴 Difficile
Camminare attraverso materiale solido in modo continuo e coerente (senza "blob"
o sezioni non tagliate) usando un portale su terreno scavabile.
**Fattibilità:** dipende dall'item 3 (mesh/voxel clipping). I portali type-2
(blocchi cavi) sono un passo verso questo, ma il taglio continuo del terreno
solido attorno al passaggio è C++ pesante.

### ❌ 12. Rilevamento e distruzione da parte dei mob ostili  · 🟢 Media
Mob attratti dai portali e/o che li distruggono quando li incontrano.
**Fattibilità:** media, Lua puro (dipende dal mob framework, es. VoxeLibre/mobs).
Pathfinding verso portale + hook per rompere il frame. Riusa il globalstep entità.

### ❌ 13. Portali che si piegano o si incrociano (Crossed portals)  · 🔴 Molto difficile
Geometria non-euclidea, percorsi complessi.
**Fattibilità:** molto alta complessità (rendering ricorsivo/multi-pass). Bassa
priorità — feature da fine progetto.

### ❌ 14. Integrazione con altri sistemi Minetest (doors, pressure plates)  · 🟢 Media
Aprire portali solo quando attivati elementi esterni (porte, pulsanti, leve) sul
lato corretto.
**Fattibilità:** media, Lua puro. API per attivazione/disattivazione portale
esiste (`close_portal`/`deactivate_if_frame`). Serve hook ai sistemi esterni
(mesecons/doors) — dipende dalle mod di terze parti installate.

---

## Bug da risolvere

> Seed da memoria di sessione + storia commit. Edge case noti / fragilità aperte —
> verificare in-game e aggiornare. Nessun marker FIXME/BUG attualmente nel codice.

- **BUG-1 — Entità a cavallo del portale = "blob".** Senza l'item 3, un'entità che
  attraversa il piano è renderizzata interamente da un lato finché non scatta il
  teleport. Effetto visivo di compenetrazione. Risoluzione = item 3.

- **BUG-2 — Roll/snap race condition.** `snapRoll` non deve sovrascrivere uno
  `snapView` pendente nello stesso frame (guard in `localplayer.h`). Fix applicato
  ma fragile: ogni modifica all'ordine di applicazione roll/view può reintrodurre
  la regressione. Da ri-testare dopo modifiche camera.

- **BUG-3 — Sink-through pavimento se il guard del collision-shift fallisce.**
  Il `floor_portal_cb_shift` è gated da `over_floor_opening()`. Se il guard non
  scatta (es. centro player ai bordi dell'apertura) il giocatore può affondare nel
  pavimento o, al contrario, restare bloccato sopra l'apertura. Verificare edge dei
  bordi.

- **BUG-4 — Convenzione param2↔front (type-2).** Deve combaciare tra Lua
  `pgun3_param2(axis,ns)` e C++ `getWallMountedDir`. Disallineamento = blocchi
  orientati male su alcune delle 6 direzioni. Testare tutte e 6.

- **BUG-5 — Flood mesh su blocchi aria.** NON chiamare `addUpdateMeshTask` in
  `updatePortalDrawList`: i blocchi aria hanno mesh null permanente → flood
  per-frame. Già evitato; tenere come trappola da non reintrodurre.

- **BUG-6 — Build AppImage non aggiornata.** Le modifiche C++ richiedono rebuild
  dell'AppImage via `release.sh`; altrimenti il vecchio C++ gira mentre il Lua si
  aggiorna → sembra un bug di feature (es. collisione cubo pieno su type-2). Non è
  un bug di codice ma causa diagnosi errate. Vedi AGENTS.MD.
