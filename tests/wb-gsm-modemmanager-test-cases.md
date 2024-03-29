## Контекст
С переходом на NM + MM, мы решили не поддерживать старые модемы в MM. В случае работы с модемом через ModemManager (далее - MM), wb-gsm должен ничего не делать и ругаться. Иначе - будем ловить конфликты вокруг занятых портов модема.

Концептуально:
*   нет NM/MM -> wb-gsm работает, как раньше
*   есть NM/MM; модем не поддерживается в MM -> wb-gsm работает, как раньше
*   есть NM/MM; модем поддерживается в MM -> wb-gsm ничего не делает, ругается и завершается с rc1

## Требования:
*   NM, MM
*   wb-configs >= 3.10.3 (с правилами udev по игнорированию модемов)

## Сценарии:
Убрать модем из webui; перезагрузить WB.

1)  Взять wbc-4g (поддерживается в MM); настроить в hwconf (можно - через webui).
Выполнить `wb-gsm should_enable; echo $?` Должно выполниться успешно (rc=0).
2)  Выполнить `wb-gsm on; echo $?` Модем включится, rc=0. *Это - нормально. MM понимает, работать с модемом или нет - через правила udev, срабатывающие при включении модема. В реальных ситуациях, поддерживаемый MM модем уже включен до того, как можно потрогать wb-gsm (через wb-gsm.service).*
3)  Выполнить `wb-gsm on; echo $?` (вместо `on` можно что-нибудь другое; все, кроме `mm_on/mm_off/should_enable`). Wb-gsm заругается на MM; rc=1.
4)  Выполнить `wb-gsm mm_off; echo $?`. Модем должен выключиться; rc=0.
5)  Перезагрузить WB. Посмотреть в `systemctl status wb-gsm.service` (должен отработать успешно). Модем должен включиться сам. Выполнить `wb-gsm on; echo $?` (вместо `on` можно что-нибудь другое; все, кроме `mm_on/mm_off/should_enable`). Wb-gsm заругается на MM; rc=1. Выполнить `mmcli --list-modems` (должны увидеть модем).
6)  Взять wbc-3g (не поддерживается в MM); выставить его в webui.
Выполнить `wb-gsm should_enable; echo $?` RC должен быть 1.
2)  Выполнить `wb-gsm on; echo $?` Модем включится, rc=0.
3)  Выполнить `wb-gsm on; echo $?` (вместо `on` можно что-нибудь другое; все, кроме `mm_on/mm_off/should_enable`). RC будет 0; всё должно выполняться успешно.
4)  Выполнить `wb-gsm off; echo $?`. Модем должен выключиться; rc=0.
5)  Перезагрузить WB. Посмотреть в `systemctl status wb-gsm.service` (должен не запуститься по exec-condition). Модем не должен включаться сам. Выполнить `wb-gsm on; echo $?` Модем включится, rc=0. Подождать пару минут; выполнить `mmcli --list-modems` (должны не увидеть ничего).
