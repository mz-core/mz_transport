# mz_transport

Backend unico do **MZ Move** (passageiro) e **MZ Move Parceiros** (motorista).

## Dependencias e ordem

O resource declara dependencias reais de `oxmysql`, `mz_core`, `mz_economy` e `mz_phone`. No `server.cfg`,
garanta que estejam iniciados antes:

```cfg
ensure oxmysql
ensure mz_core
ensure mz_economy
ensure mz_phone
ensure mz_transport
```

`mz_bank` deve continuar na ordem ja adotada pelo servidor para disponibilizar a experiencia
bancaria, mas o settlement usa diretamente o export atomico que tambem e a autoridade do banco:
`exports['mz_economy']:TransferBankBetweenPlayers(...)`. Nao existe ledger nem writer financeiro no `mz_transport`.

## Banco de dados

O schema e preparado de forma idempotente ao iniciar o resource. Para aplicacao manual:

```text
source mz_transport/sql/001_mz_transport.sql
```

Tabelas: `mz_transport_schema_migrations`, `mz_transport_drivers`,
`mz_transport_rides` e `mz_transport_ratings`.

## Provider de populacao

O provider standalone implementa o contrato `CreateDriver`, `Ready`, `Status` e `Cleanup`.
Uma futura integracao `population_mz.lua` deve implementar esse mesmo contrato. O provider
controla somente entidades; corrida, preco, matching, pagamento e historico permanecem nos
services centrais.

## Testes locais

Da pasta do resource:

```powershell
lua tests/unit.lua
lua tests/payment.lua
lua tests/rating.lua
lua tests/driver.lua
node --test tests/phone_contract.test.js
```

Os testes locais cobrem preco, tarifa minima, comissao, coordenadas invalidas, transicoes,
double accept, contrato financeiro, avaliacoes e o contrato de integracao dos dois apps.
Fluxos com entidades, OneSync, NUI renderizada, oxmysql e dinheiro real exigem staging FiveM.

## Teste no servidor

1. Inicie os resources na ordem acima e confirme `[MZ_TRANSPORT] ready`.
2. Passageiro: marque um waypoint, abra **MZ Move**, calcule e solicite.
3. Motorista: entre no banco do motorista de um veiculo permitido, abra
   **MZ Move Parceiros** e fique online.
4. Aceite a oferta; os waypoints mudam automaticamente para passageiro e destino.
5. Embarque no mesmo veiculo. A viagem inicia e conclui por distancia server-side.
6. Confira o extrato/ledger do `mz_core`, o historico dos dois apps e envie a avaliacao.
7. Repita com dois motoristas para verificar que apenas o primeiro aceite vence.
8. Teste cancelamento antes/depois do aceite e desconexao de cada papel.
9. Para NPC, deixe todos os motoristas offline e aguarde `Config.NPCDriver.DelayBeforeOffer`.
10. Ative `Config.Debug` somente em staging para diagnostico adicional.
