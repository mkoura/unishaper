#!/bin/sh
#
# Martin Kourim <martin@kourim.net>
#
# konzultace ochotne poskytl Miroslav Jezbera, MeliAP <jezz@hkfree.org>
# puvodni HTB shaper vymyslel Ladislav Pecho, JNet <lada@hkfree.org>

# verze: 0.2508200501


## vychozi konfiguracni soubor
config="/usr/local/etc/unishaper.conf"

## vychozi hodnoty nekterych parametru ('empty' znamena ze parametr je prazdny)
# HTB
range_def='empty'
not_shape_def='empty'
class_name_def='empty'
parent_def='empty'
nest_qdisc_type_def='empty'
dist_def='empty'
default_rate_def='empty'
dist_def='yes'
use_imq_def='no'
function_def=':'
main_qdisc_def='htb'
unit_def='kbit'
r2q_def='3'
# PRIO
priomap_prio_def=3
bands_prio_def=3
function_prio_def=':'
function_tprio_def=':'
protocols_tprio_def='empty'
tcp_dports_tprio_def='empty'
udp_dports_tprio_def='empty'
tcp_sports_tprio_def='empty'
udp_sports_tprio_def='empty'
nest_qdisc_type_tprio_def='empty'
# SFQ
function_sfq_def=':'
perturb_sfq_def='10'
# ESFQ
function_esfq_def=':'
perturb_esfq_def='10'
dist_esfq_def='empty'
# TBF
unit_tbf_def='kbit'
function_tbf_def=':'
# bfifo
function_bfifo_def=':'
# pfifo
function_pfifo_def=':'

###


#
# ruzne pomocne funkce
#

# napoveda
f_help()
{
  cat <<EoF
Pouziti: $progname [VOLBY]
volby:
  -c, --config soubor.conf  cesta ke konfiguracnimu souboru
  -d, --debug      nic se nenastavi, prikazy se jen vypisou
  -g, --gen        nic se nenastavi, vypisi se jen prikazy pro pouziti jako
                   staticky skript
  -G, --gen2       stejne jako -g, ale provedou se i testy (vhodne pro
                   generovani skriptu na cilovem pocitaci)
  -n, --nocheck    nekontrolovat spravne provedeni dulezitych prikazu
  -p, --time       nic se nenastavi ani nevypise. Slouzi jen k mereni rychlosti
                   samotneho skriptu (time ./unishaper.sh --time)
  -r, --rate       zkontroluje jestli je nastaveny dostatecne vysoky 'rate'
                   a 'ceil' ve vsech tridach a podtridach HTB
  -s, --stop       "zastavit" shaper
  -S, --status DEV vypise informace o nastaveni na konkretnim interfacu
  -t, --tests      provede jen testy, jestli mame vse co je pri stavajici
                   konfiguraci potreba. Kdyz se nevypise chybova hlaska, je vse
                   v poradku.
  --help           vypise tuhle "napovedu"
EoF
}

# chybovy vypis
perror()
{
  echo "$progname: CHYBA: $@" >&2
  return 0
}

# kontrola navratove hodnoty prikazu
f_check()
{
  eval "$@" >/dev/null \
    || { local retval="$?"; perror "${@}: prikaz selhal"; $clean; exit "$retval"; }
  return 0
}

# nastaveni parametru
#   volba_z_konf_souboru, parametr
set_param()
{
  # smazeme predchozi nastaveni teto volby
  unset $2
  # kdyz je volba uvedena v konf. souboru, rovnou ji nastavime
  if eval [ -n \"\$${1}\" ]; then
    eval $2=\"\$${1}\"
  else
    # kdyz volba neni nastavena v konf. souboru, koukneme se jestli ma
    # nejakou vychozi hodnotu
    eval local param=\"\$${2}_def\"
    if [ -n "$param" ]; then
      # kdyz je vychozi hodnota 'empty', parametr ma byt prazdny
      [ "$param" = 'empty' ] && eval $2='' || eval $2=\"${param}\"
      #$echo "param2 = $param2 promenna = $2"
    else
      perror "neni nastaveny parametr $1 u $iface"
      $clean
      exit 1
    fi
  fi
  # volbu z konf. souboru smazeme (musime, jinak by nam tam zustala i pri
  # nastaveni dalsiho interfacu, pokud bysme ji neprepsali)
  unset $1

  return 0
}

# sestaveni nepovinnych parametru qdiscu
#   nazev_parametru, volba_z_konf_souboru, nazev_promenne
# do nazev_promenne prida retezec $nazev_parametru $volba_z_konf_souboru
# napr. r2q 3
qdisc_param()
{
  eval [ -n \"\$${2}\" ] \
  && {
    eval $3=\"\$${3} $1 \$${2}\"
    unset $2
  }

  return 0
}

# parsovani seznamu IP adres - pomocna funkce, ktera nastavi promenne
# source_type a ips_source
# parametry: nazev promenne se zdrojem IP adres (seznam IP adres nebo soubor)
# v pripade IP adres v samostatnem souboru prenastavi promennou IFS, takze
# po volani funkce f_range je nutne nastavit IFS zpet na $oldifs
f_source()
{
  eval [ -z \"\$${1}\" ] && return 1
  eval local tmp_file=\"\${${1}#file:}\"
  if eval [ \"\$${1}\" != \"$tmp_file\" ]; then
    [ ! -e "$tmp_file" ] \
      && { perror "${tmp_file}: soubor neexistuje"; $clean; exit 1; }
    source_type='file'
    ips_source="$tmp_file"
    IFS="$newline"
  else
    source_type='list'
    ips_source="$1"
  fi

  return 0
}

# parsovani IP adres
#   typ_zdroje_ip_adres zdroj_ip_adres
# nacitame IP adresy ze samostatneho souboru, nebo jsou zapsany na jednom
# radku v konf. souboru?
f_range()
{
  case "$1" in
    file )
      cat "$2"
      ;;
    list )
      for i in $(eval echo \"\$${2}\"); do
        local tmp_base_ip="${i%.*}"
        i="${i##*.}"
        local od="${i%-*}"
        local do="${i#*-}"
        [ "$od" = "$do" ] \
        && {
          echo "${tmp_base_ip}.${od}"
          continue
        }
        [ "$do" -lt "$od" ] \
        && {
          perror "spatne zadany rozsah ${od}-${do} u ${act}${qtree}_range u $iface"
          $clean
          exit 1
        }
        while [ "$od" -le "$do" ]; do
          echo "${tmp_base_ip}.${od}"
          local od="$(($od + 1))"
        done
      done
      ;;
  esac

  return 0
}

# vycisteni v pripade chyby
f_clean()
{
  # aby nedoslo k zacykleni
  [ "$clean_loop" = 'yes' ] \
  && {
    perror "koncim, je potreba spustit tento skript rucne s parametrem -s"
    exit 1
  }
  local clean_loop='yes'
  stop_only='yes'
  tests='no'
  inum=0
  imqnum=-1
  main_loop
  f_iptables_stop 2>/dev/null
  # cistici funkce definovana v konf. souboru
  eval $clean_function

  return 0
}

# jednoduchy vypis nastaveni pro konkretni interface
f_status()
{
  echo "QDISC:"
  $check $tc -s qdisc show dev "$1"
  echo
  echo "CLASS:"
  $check $tc -s class show dev "$1"

  return 0
}

#
# testy jestli mame vsechno co potrebujeme
#

f_tests()
{
  [ "$tests" != 'yes' ] && return 0

  # mame tc?
  $tc -help >/dev/null 2>&1
  [ "$?" -eq 127 ] \
  && {
    perror "prikaz tc nenalezen. Je potreba nainstalovat iproute2, nebo" \
    "nastavit spravne promennou 'tc'."
    exit 1
  }

  return 0
}

f_test_ipt()
{
  [ "$has_ipt" = 'yes' ] && return 0
  has_ipt='yes'
  [ "$tests" != 'yes' ] && return 0

  # mame iptables?
  $iptables --version >/dev/null 2>&1
  [ "$?" -eq 127 ] \
  && {
    perror "prikaz iptables nenalezen. Je potreba nainstalovat iptables," \
    "nebo nastavit spravne promennou 'iptables'."
    $clean
    exit 1
  }

  # umi iptables -j MARK?
  $iptables -t mangle -A POSTROUTING -s 192.168.254.254/32 -j MARK \
    --set-mark 3 >/dev/null 2>&1 \
    || {
      perror "iptables neumi -j MARK, asi chybi libipt_MARK.so." \
      "Je potreba nainstalovat kompletni iptables, pripadne zkontrolovat" \
      "jestli mate prava roota."
      $clean
      exit 1
    }
  $iptables -t mangle -D POSTROUTING -s 192.168.254.254/32 -j MARK \
    --set-mark 3 >/dev/null 2>&1

  return 0
}

# umi iptables -m length?
# neni nezbytne potreba, takze kdyz neumi, nic se nedeje
f_test_length()
{
  case "$has_len" in
    yes ) return 0 ;;
    no ) return 1 ;;
  esac
  has_len='yes'
  [ "$tests" != 'yes' ] && return 0

  $iptables -t mangle -A INPUT -i lo -p tcp --tcp-flags ALL ACK -m length \
    --length 40:100 -j MARK --set-mark 3 >/dev/null 2>&1 \
    || {
      has_len='no'
      perror "iptables neumi -m length. Nebude se proto pouzivat."
      return 1
    }
  $iptables -t mangle -D INPUT -i lo -p tcp --tcp-flags ALL ACK -m length \
    --length 40:100 -j MARK --set-mark 3

  return 0
}

f_test_imq()
{
  [ "$has_imq" = 'yes' ] && return 0
  has_imq='yes'

  # zavedeme modul imq, pokud jeste neni zavedeny
  $dbg modprobe imq numdevs="$imqnumdevs" 2>/dev/null

  [ "$tests" != 'yes' ] && return 0

  # jsme IMQ ready?
  $iptables -t mangle -A POSTROUTING -s 192.168.254.254/32 -j IMQ \
    --todev imq0 >/dev/null 2>&1 \
    || {
      perror "je zapnute shapovani vstupu pro ${iface}, ale vase iptables" \
      "neumi IMQ. Vice v README."
      $clean
      exit 1
    }
  $iptables -t mangle -D POSTROUTING -s 192.168.254.254/32 -j IMQ \
    --todev imq0 >/dev/null 2>&1

  # mame prikaz ip?
  $ip link set imq0 down >/dev/null 2>&1
  [ "$?" -eq 127 ] \
  && {
    perror "prikaz ip nenalezen. Je potreba nainstalovat iproute2, nebo" \
    "nastavit spravne promennou 'ip'."
    $clean
    exit 1
  }

  # umi jadro IMQ?
  $ip link set imq0 up >/dev/null 2>&1 \
    || {
      perror "je zapnute shapovani vstupu pro ${iface}, ale vase jadro" \
      "neumi IMQ. Vice v README."
      $clean
      exit 1
    }
  $ip link set imq0 down >/dev/null 2>&1

  return 0
}

# jsme ESFQ ready?
f_test_esfq()
{
  [ "$has_esfq" = 'yes' ] && return 0
  has_esfq='yes'
  [ "$tests" != 'yes' ] && return 0

  $tc qdisc add dev lo root esfq perturb 10 hash dst >/dev/null 2>&1 \
    || {
      perror "vas kernel nebo tc nepodporuje esfq. Vice v README."
      $clean
      exit 1
    }
  $tc qdisc del dev lo root >/dev/null 2>&1

  return 0
}

#
# nastaveni iptables
#

# maze pravidla iptables zavedena unishaperem
f_iptables_stop()
{
  $dbg $iptables -t mangle -D PREROUTING -j unishaper_pre
  $dbg $iptables -t mangle -D POSTROUTING -j unishaper_post
  $dbg $iptables -t mangle -D INPUT -j unishaper_in
  $dbg $iptables -t mangle -D OUTPUT -j unishaper_out
  $dbg $iptables -t mangle -D FORWARD -j unishaper_fw
  $dbg $iptables -t mangle -F unishaper_pre
  $dbg $iptables -t mangle -F unishaper_post
  $dbg $iptables -t mangle -F unishaper_in
  $dbg $iptables -t mangle -F unishaper_out
  $dbg $iptables -t mangle -F unishaper_fw
  $dbg $iptables -t mangle -X unishaper_pre
  $dbg $iptables -t mangle -X unishaper_post
  $dbg $iptables -t mangle -X unishaper_in
  $dbg $iptables -t mangle -X unishaper_out
  $dbg $iptables -t mangle -X unishaper_fw

  return 0
}

# vytvari nove retezce
f_iptables_start()
{
  [ "$ipt_start" = 'yes' ] && return 0
  ipt_start='yes'

  # smazeme pravidla iptables
  f_iptables_stop 2>/dev/null

  $check $iptables -t mangle -N unishaper_pre
  $check $iptables -t mangle -N unishaper_post
  $check $iptables -t mangle -N unishaper_in
  $check $iptables -t mangle -N unishaper_out
  $check $iptables -t mangle -N unishaper_fw

  return 0
}

#
# nastavujeme korenovy qdisc, tj. hlavni qdisc pro dany interface
#

f_init_global()
{
  # korenovy qdisc je vzdy 1
  qdiscid=1
  qtree=''

  # minuly qdisc - potrebujeme znat napr. pri pouziti
  # IMQ pro vstup i vystup
  last_qdisc="$main_qdisc"
  set_param "${act}_qdisc_type" main_qdisc

  # nastaveni HTB qdiscu specificka pro korenovou
  # a default tridu
  if [ "$main_qdisc" = 'htb' ]; then
    f_test_ipt
    # zaciname znackovat od jakeho cisla? (1 - root, 2 - local, 3 - notshape,
    # $ifaceid az $ifaceid + $imqnumdevs - oznaceni interfacu)
    classid=50
    # vychozi nastaveni cisla rodicovske tridy je 1 (korenova trida
    parentcl=1
    # rodicovska trida s nazvem 'local' ma cislo 2
    cln_local=2
    # pakety ktere se maji vyhnout shaperu patri do tridy 3
    notshape=3

    for i in root_rate r2q function unit dist; do
      set_param "${act}_${i}" "$i"
    done

    # chceme nastavit 'default' tridu?
    set_param "${act}_rate" default_rate
    default_htb_param=''
    if [ -z "$default_rate" ]; then
      unset ${act}_ceil default_ceil ${act}_burst ${act}_mpu ${act}_overhead \
        ${act}_cburst ${act}_mtu ${act}_prio ${act}_quantum
    else
      set_param "${act}_ceil" default_ceil
      for i in burst mpu overhead cburst mtu prio quantum; do
        qdisc_param "$i" "${act}_${i}" default_htb_param
      done
    fi

    # nastaveni nekterych voleb pro iptables (zajima nas vstup nebo vystup
    # na/z interface, source nebo destination, atd. Zavisi na nastaveni 'dist')
    if [ "$act" = 'in' ]; then
      unset use_imq
      lsd='-s'; liptchain='in'
      io='-i'
      if [ "$dist" = 'yes' ]; then
        # XXX - u lokalniho trafficu nemuze byt postrouting...
        sd='-d'; iptchain='post'
        imqinit_fun='f_input_comm_dist'
        imqinit_fun_local='f_input_comm_dist_local'
      else
        sd='-s'; iptchain='pre'
        imqinit_fun='f_input_comm'
        imqinit_fun_local=':'
      fi
    else
      lsd='-d'; liptchain='out'
      io='-o'
      iptchain='post'
      [ "$dist" = 'yes' ] && sd='-s' || sd='-d'

      # pouzivame IMQ i pro vystup (output)?
      set_param out_use_imq use_imq
      [ "$use_imq" = 'yes' ] \
      && {
        [ "$input" != 'yes' ] \
        && {
          perror "neni nastaveno shapovani inputu (vstupu), takze" \
          "out_use_imq nema smysl"
          $clean
          exit 1
        }
        [ "$last_qdisc" != 'htb' ] \
        && {
          perror "in_qdisc_type neni HTB, takze out_use_imq nema smysl"
          $clean
          exit 1
        }
        f_test_imq
        # zapneme IMQ
        $check $iptables -t mangle -I unishaper_post -o "$iface" \
          -j IMQ --todev "$imqnum"
        sdev="imq${imqnum}"
      }
    fi

    f_iptables_start
  else
    # dalsi nastaveni qdiscu
    f_init_${main_qdisc}
  fi

  return 0
}

#
# nastaveni jednotlivych qdiscu - mohou byt korenove, vnorene, atd.
#

f_init_htb()
{
  for i in rate ceil unit; do
    set_param "${act}${qtree}_${i}" "$i"
  done
  htb_param=''
  for i in burst mpu overhead cburst mtu prio quantum; do
    qdisc_param "$i" "${act}${qtree}_${i}" htb_param
  done

  return 0
}

f_init_htb_clean()
{
  for i in rate ceil unit; do
    unset ${act}${qtree}_${i} $i
  done
  htb_param=''
  for i in burst mpu overhead cburst mtu prio quantum; do
    unset ${act}${qtree}_${i}
  done

  return 0
}

# pomocna funkce pro HTB
f_init_htb_pom()
{
  for i in range class_name function not_shape; do
    set_param "${act}${qtree}_${i}" "$i"
  done
  # zarazka - kdyz uz neni co nastavit, uklizime a vracime 1
  [ -z "$range" -a -z "$class_name" -a "$not_shape" != 'yes' -a "$function" = ':' ] \
    && { unset $clname_list clname_list; return 1; }

  for i in nest_qdisc_type parent; do
    set_param "${act}${qtree}_${i}" "$i"
  done

  # je potomkem ktere tridy?
  parentcl=1
  [ -n "$parent" ] \
  && {
    if [ "$parent" = 'local' ]; then
      [ -n "$class_name" ] \
      && {
        perror "potomek tridy 'local' nemuze byt rodic" \
        "(${act}${qtree}_class_name nema smysl)"
        $clean
        exit 1
      }
      parentcl='3'
    else
      # nacteme cislo tridy rodice
      eval parentcl=\"\$cln_${parent}\"
      [ -z "$parentcl" ] \
      && {
        perror "trida s nazvem '$parent' neexistuje"
        $clean
        exit 1
      }
    fi
  }

  # je to budouci "rodic" nejake tridy?
  if [ -n "$class_name" ]; then
    # nastavime dalsi parametry qdiscu
    f_init_htb

    eval [ -n \"\$cln_${class_name}\" ] \
    && {
      perror "trida s nazvem '$class_name' uz existuje"
      $clean
      exit 1
    }
    # ulozime cislo tridy
    eval cln_${class_name}=\"$(($classid + 1))\"
    # kvuli uklidu - nazvy a ulozena cisla trid musime nakonec smazat
    clname_list="$clname_list cln_${class_name}"
    # je to jen jedna trida, takze zadne IP adresy nepotrebujeme
    range=''
    # tohle tady nefunguje
    not_shape=''
    # tuhle volbu sice nepotrebujeme, ale musime ji aspon smazat
    # (protoze to za nas neudela set_param)
    unset ${act}${qtree}_dist
  else
    # nastavime nebo smazeme dalsi parametry qdiscu
    if [ "$not_shape" = 'yes' ]; then
      f_init_htb_clean
      [ -z "$range" -a "$parent" != 'local' ] \
      && {
        perror "pri nastaveni '${act}${qtree}_not_shape' u $iface je nutne" \
        "nastavit take '${act}${qtree}_range'."
        $clean
        exit 1
      }
    else
      f_init_htb
    fi

    # nastavili jsme nejaky "vnoreny" qdisc?
    nest_qdisc_htb=':'
    [ -n "$nest_qdisc_type" -a "$nest_qdisc_type" != 'tbf' ] \
      && f_init_nest_qdisc "$nest_qdisc_type" nest_qdisc_htb
  fi

  return 0
}

f_init_sfq()
{
  for i in perturb function; do
    set_param "${act}${qtree}_${i}_sfq" ${i}_sfq
  done
  sfq_param=''
  for i in quantum limit; do
    qdisc_param "$i" "${act}${qtree}_${i}_sfq" sfq_param
  done

  return 0
}

f_init_esfq()
{
  f_test_esfq

  for i in perturb function dist; do
    set_param "${act}${qtree}_${i}_esfq" ${i}_esfq
  done

  # kdyz je ESFQ vnoreny do HTB, prevezmeme od HTB nastaveni 'dist'
  if [ "$main_qdisc" = 'htb' ]; then
    dist_esfq="$dist"
  elif [ -z "$dist_esfq" ]; then
    dist_esfq='yes'
  fi

  esfq_param=''
  for i in quantum depth divisor limit; do
    qdisc_param "$i" "${act}${qtree}_${i}_esfq" esfq_param
  done

  # zajima nas source, nebo destination?
  if [ "$act" = 'in' ]; then
    [ "$dist_esfq" = 'yes' ] && ssd='dst' || ssd='src'
  else
    [ "$dist_esfq" = 'yes' ] && ssd='src' || ssd='dst'
  fi

  return 0
}

f_init_prio()
{
  for i in bands priomap function; do
    set_param "${act}${qtree}_${i}_prio" "${i}_prio"
  done

  # kdyz ma 'bands' jinou hodnotu nez 3, musime prenastavit i 'priomap'
  if [ -n "$priomap_prio" ]; then
    priomap_prio="priomap $priomap_prio"
  else
    [ "$bands_prio" -ne 3 ] \
    && {
      perror "pokud je hodnota ${act}_bands_prio jina nez 3, je nutne nastavit" \
      "${act}_priomap_prio."
      $clean
      exit 1
    }
  fi

  local tmp_qtree_prio="$qtree"
  local tmp_prionum=1

  # Musime nacist najednou hodnoty pro vsechny tridy, protoze vickrat
  # nez jednou je z konf. souboru neprecteme a PRIO muze byt "vnoreno"
  # do nekolika HTB trid.
  # (pri kazdem nacteni nejake volby smaze funkce set_param prislusne nastaveni
  # z konf. souboru)
  while [ "$bands_prio" -ge "$tmp_prionum" ]; do
    # PRIO je classfull qdisc a muze byt "vnoreny" treba do HTB. Zaroven
    # ale muze byt do PRIO tridy "vnoreny" dalsi qdisc. Takze pro nastaveni
    # vnoreneho qdiscu musi tato funkce zmenit qtree a nakonec ho musi zase
    # vratit zpet na puvodni hodnotu.
    qtree="${tmp_qtree_prio}_${tmp_prionum}"

    # nastavime dalsi parametry qdiscu
    for i in protocols tcp_dports udp_dports tcp_sports udp_sports \
             nest_qdisc_type function
    do
      set_param "${act}${qtree}_${i}_prio" "${i}_tprio"
      eval ${i}_${tmp_prionum}_prio=\"\$${i}_tprio\"
    done

    # nastaveni vnoreneho qdiscu pro konkretni PRIO tridu
    eval nest_qdisc_${tmp_prionum}_prio=':'
    eval local tmp_var=\"\$nest_qdisc_type_${tmp_prionum}_prio\"
    [ -n "$tmp_var" -a "$tmp_var" != 'prio' ] \
      && f_init_nest_qdisc "$tmp_var" nest_qdisc_${tmp_prionum}_prio

    local tmp_prionum="$(($tmp_prionum + 1))"
  done

  # vratime zpet puvodni hodnotu qtree
  qtree="$tmp_qtree_prio"

  return 0
}

f_init_tbf()
{
  for i in rate unit function; do
    set_param "${act}${qtree}_${i}_tbf" "${i}_tbf"
  done
  tbf_param=''
  for i in limit latency burst mpu peakrate mtu; do
    qdisc_param "$i" "${act}${qtree}_${i}_tbf" tbf_param
  done

  return 0
}

f_init_bfifo()
{
  set_param "${act}${qtree}_function_bfifo" function_bfifo
  bfifo_param=''
  qdisc_param limit "${act}${qtree}_limit_bfifo" bfifo_param

  return 0
}

f_init_pfifo()
{
  set_param "${act}${qtree}_function_pfifo" function_pfifo
  pfifo_param=''
  qdisc_param limit "${act}${qtree}_limit_pfifo" pfifo_param

  return 0
}

# nastaveni qdiscu "vnoreneho" do jineho qdiscu
#   qdisc, promenna ktera ma ukazovat na pozadovanou funkci
f_init_nest_qdisc()
{
  case "$1" in
    htb )
      # HTB nemuze byt "vnoreny" do jineho qdiscu
      eval $2=':'
      return 0
      ;;
    * )
      f_init_${1}
      ;;
  esac

  eval $2=f_nest_${1}

  return 0
}

#
# kontrola nastaveni rate a ceil
#

rate_control()
{
  # viz main_loop
  while : ; do
    unset iface input output

    iface${inum} 2>/dev/null || { [ "$?" -eq 127 ] && return 0; }
    [ -z "$iface" ] && { inum="$(($inum + 1))"; continue; }
    [ "$input" = 'yes' ] \
    && {
        act='in'
        f_rate_control_in
    }
    [ "$output" = 'yes' ] \
    && {
        act='out'
        f_rate_control_in
    }
    inum="$(($inum + 1))"
  done

  exit 0
}

f_rate_control_in()
{
  # pokud se nejedna o HTB, neni co pocitat...
  last_qdisc="$main_qdisc"
  set_param "${act}_qdisc_type" main_qdisc
  [ "$main_qdisc" != 'htb' ] && return 0

  # pokud pouzivame IMQ i pro vystup, musime nastaveni korenove tridy
  # "prenest" az do kontroly vystupu. Takze pri kontrole vstupu korenovou
  # tridu zatim netestujeme, nevypisujeme ani "neuklizime".
  local classlist='root'
  if [ "$act" = 'in' ]; then
    use_imq=''
    [ "$out_use_imq" = 'yes' ] && local classlist=''
  else
    set_param out_use_imq use_imq
  fi

  # pokud $use_imq == yes, pouzivame IMQ i pro vystup
  # a nasledujici parametry zname uz z nastveni vstupu (inputu)
  if [ "$use_imq" != 'yes' ]; then
    set_param "${act}_root_rate" cln_root_rate_orig
    set_param "${act}_rate" default_rate
    set_param "${act}_unit" unit

    cln_root_rate_orig="$(f_preved "$cln_root_rate_orig" "$unit")"

    [ -n "$default_rate" ] \
    && {
      set_param "${act}_ceil" default_ceil
      default_rate="$(f_preved "$default_rate" "$unit")"
      default_ceil="$(f_preved "$default_ceil" "$unit")"
      cln_root_rate="$default_rate"
      # ceil default tridy nesmi byt vetsi nez rate korenove tridy
      [ "$default_ceil" -gt "$cln_root_rate_orig" ] \
        && perror "hodnota volby '${act}_ceil' u $iface je vyssi nez hodnota" \
        "'${act}_root_rate'. Je nutne snizit '${act}_ceil'."
    }
  else
    [ "$input" != 'yes' ] \
    && {
      perror "neni nastaveno shapovani inputu (vstupu), takze out_use_imq" \
      "nema smysl"
      exit 1
    }
    [ "$last_qdisc" != 'htb' ] \
    && {
      perror "in_qdisc_type neni HTB, takze out_use_imq nema smysl"
      exit 1
    }
  fi

  # skupiny trid
  local unum=1
  while : ; do
    for i in range class_name function not_shape; do
      set_param "${act}_${unum}_${i}" "$i"
    done

    # kdyz uz neni co nastavit, koncime
    [ -z "$range" -a -z "$class_name" -a "$not_shape" != 'yes' -a "$function" = ':' ] && break

    # not_shape nefunguje, pokud je nastavene class_name
    [ -n "$class_name" ] && not_shape=''

    # uz neni co nastavit
    [ "$not_shape" = 'yes' ] \
    && {
      unset ${act}_${unum}_rate rate ${act}_${unum}_ceil ceil \
        ${act}_${unum}_unit unit ${act}_${unum}_parent parent
      continue
    }

    for i in rate ceil unit parent; do
      set_param "${act}_${unum}_${i}" "$i"
    done

    # local je jen 'pseudo' trida
    [ "$parent" = 'local' ] && parent=''

    rate="$(f_preved "$rate" "$unit")"
    ceil="$(f_preved "$ceil" "$unit")"

    # existuje "rodicovska" trida?
    eval [ -n \"$parent\" -a -z \"\$cln_${parent}_rate_orig\" ] \
    && {
      perror "trida s nazvem '$parent' neexistuje"
      exit 1
    }

    local num_ip=1
    # je to budouci "rodic" nejake tridy?
    if [ -n "$class_name" ]; then
      eval [ -n \"\$cln_${class_name}\" ] \
      && {
        perror "trida s nazvem '$class_name' uz existuje"
        exit 1
      }
      # u kazde tridy ktera je "rodic" nejakych dalsich trid si ulozime
      # hodnotu rate, abysme meli s cim porovnavat
      eval cln_${class_name}_rate_orig=\"$rate\"
      # pridame do seznamu trid, ktere budeme nakonec kontrolovat
      local classlist="$classlist $class_name"
    else
      # zjistime pocet IP adres
      [ -n "$range" ] && local num_ip="$(f_pocet range)"
    fi

    # porovname ceil vnorene tridy s rate "rodicovske" tridy
    eval [ \"$ceil\" -gt \"\$cln_${parent:=root}_rate_orig\" ] \
      && perror "hodnota volby '${act}_${unum}_ceil' u $iface je vyssi nez" \
         "hodnota 'rate' u tridy pojmenovane '${parent}'." \
         "Je potreba snizit '${act}_${unum}_ceil'."

    # pricteme rate
    eval local tmp_var=\"\$cln_${parent}_rate\"
    eval cln_${parent}_rate=\"$(($num_ip * $rate + ${tmp_var:-0}))\"

    local unum="$(($unum + 1))"
  done

  # kontrolujeme hodnoty rate "rodicovske" tridy se souctem rate
  # vnorenych trid
  for i in $classlist; do
    eval local tmp_var=\"\$cln_${i}_rate\"
    eval local tmp_var2=\"\$cln_${i}_rate_orig\"
    [ "${tmp_var:-0}" -gt "$tmp_var2" ] \
    && {
      perror "hodnota volby 'rate' u tridy pojmenovane '$i' u $iface je" \
      "prilis nizka. Je nutne snizit 'rate' v jejich podtridach nebo zvysit" \
      "'rate' ve tride '$i' MINIMALNE (!!!) na $tmp_var kbit."
    }
    # uklid
    unset cln_${i}_rate cln_${i}_rate_orig
  done

  return 0
}

# vypise pocet HTB trid v dane skupine trid
f_pocet()
{
  eval local tmp_file=\"\${${1}#file:}\"

  # naciteme IP adresy ze samostatneho souboru, nebo jsou zapsany na jednom
  # radku v konf. souboru?
  if eval [ \"\$${1}\" != \"$tmp_file\" ]; then
    [ ! -e "$tmp_file" ] \
      && { perror "${tmp_file}: soubor neexistuje"; exit 1; }
    # pocet radku == pocet trid
    wc -l < "$tmp_file"
  else
    local tmp_num_ip=0
    for i in $(eval echo \"\$${1}\"); do
      i="${i##*.}"
      local od="${i%-*}"
      local do="${i#*-}"
      [ "$od" = "$do" ] \
      && {
        local tmp_num_ip="$((1 + $tmp_num_ip))"
        continue
      }
      [ "$do" -lt "$od" ] \
      && {
        perror "spatne zadany rozsah ${od}-${do} u ${act}_${unum}_range u $iface"
        exit 1
      }
      local tmp_num_ip="$(($do - $od + 1 + $tmp_num_ip))"
    done

    # vypiseme pocet trid
    echo "$tmp_num_ip"
  fi

  return 0
}

# prevod z ruznych jednotek na kbit
f_preved()
{
  case "$2" in
    bps)
      echo "$(($1 / 128))" ;; # ($1 * 8) / 1024
    kbps)
      echo "$(($1 * 8))" ;;
    mbps)
      echo "$(($1 * 8192))" ;; # $1 * 8 * 1024
    kbit)
      echo "$1" ;;
    mbit)
      echo "$(($1 * 1024))" ;;
  esac

  return 0
}

#
# INPUT -- nastaveni IMQ
#

f_input_comm()
{
  $check $iptables -t mangle -I unishaper_pre -i "$iface" -j IMQ --todev "$imqnum"
  $check $ip link set imq$imqnum up

  return 0
}

f_input_comm_dist()
{
  $check $iptables -t mangle -A unishaper_fw -i "$iface" -j MARK \
    --set-mark "$ifaceid"
  $check $iptables -t mangle -I unishaper_post --mark "$ifaceid" \
    -j IMQ --todev "$imqnum"
  $check $ip link set imq$imqnum up
  ifaceid="$(($ifaceid + 1))"

  return 0
}

#
# funkce pro zavadeni qdiscu
#

# pomocna funkce pro PRIO
f_qdisc_prio()
{
  # nastaveni pro jednotlive PRIO tridy
  local prionum=1
  while [ "$bands_prio" -ge "$prionum" ]; do
    # vytvorit pravidla
    eval local tmp_var=\"\$protocols_${prionum}_prio\"
    for i in $tmp_var; do
      $check $tc filter add dev "$sdev" parent ${1}: prio "$prionum" \
        protocol ip u32 \
	match ip protocol "$i" 0xff \
	flowid ${1}:${prionum}
    done
    eval local tmp_var=\"\$tcp_dports_${prionum}_prio\"
    for i in $tmp_var; do
      $check $tc filter add dev "$sdev" parent ${1}: prio "$prionum" \
        protocol ip u32 \
        match ip protocol 6 0xff \
        match ip dport "$i" 0xffff \
        flowid ${1}:${prionum}
    done
    eval local tmp_var=\"\$udp_dports_${prionum}_prio\"
    for i in $tmp_var; do
      $check $tc filter add dev "$sdev" parent ${1}: prio "$prionum" \
        protocol ip u32 \
        match ip protocol 17 0xff \
        match ip dport "$i" 0xffff \
        flowid ${1}:${prionum}
    done
    eval local tmp_var=\"\$tcp_sports_${prionum}_prio\"
    for i in $tmp_var; do
      $check $tc filter add dev "$sdev" parent ${1}: prio "$prionum" \
        protocol ip u32 \
        match ip protocol 6 0xff \
        match ip sport "$i" 0xffff \
        flowid ${1}:${prionum}
    done
    eval local tmp_var=\"\$udp_sports_${prionum}_prio\"
    for i in $tmp_var; do
      $check $tc filter add dev "$sdev" parent ${1}: prio "$prionum" \
        protocol ip u32 \
        match ip protocol 17 0xff \
        match ip sport "$i" 0xffff \
        flowid ${1}:${prionum}
    done

    # spusteni uzivatelem definovane funkce
    eval \$function_${prionum}_prio $1

    # zavedeni "vnoreneho" qdisku
    eval \$nest_qdisc_${prionum}_prio $1 $prionum

    local prionum="$(($prionum + 1))"
  done

  return 0
}

# vnorene qdiscy

f_nest_sfq()
{
  qdiscid="$(($qdiscid + 1))"

  # zavedeni qdiscu
  $check $tc qdisc add dev "$sdev" parent ${1}:${2} handle ${qdiscid}: sfq \
    perturb "$perturb_sfq" $sfq_param

  # spusteni uzivatelem definovane funkce
  eval $function_sfq $1 $2

  return 0
}

f_nest_esfq()
{
  qdiscid="$(($qdiscid + 1))"

  $check $tc qdisc add dev "$sdev" parent ${1}:${2} handle ${qdiscid}: esfq \
    perturb "$perturb_esfq" $esfq_param hash "$ssd"

  eval $function_esfq $1 $2

  return 0
}

f_nest_prio()
{
  qdiscid="$(($qdiscid + 1))"

  $check $tc qdisc add dev "$sdev" parent ${1}:${2} handle ${qdiscid}: \
    prio bands "$bands_prio" "$priomaps"

  eval $function_prio $1 $2

  # spusteni pomocne funkce
  f_qdisc_prio "$qdiscid"

  return 0
}

f_nest_tbf()
{
  qdiscid="$(($qdiscid + 1))"

  $check $tc qdisc add dev "$sdev" parent ${1}:${2} handle ${qdiscid}: tbf \
    rate "${rate_tbf}${unit_tbf}" $tbf_param

  eval $function_tbf $1 $2

  return 0
}

f_nest_bfifo()
{
  qdiscid="$(($qdiscid + 1))"

  $check $tc qdisc add dev "$sdev" parent ${1}:${2} handle ${qdiscid}: bfifo \
    $bfifo_param

  eval $function_bfifo $1 $2

  return 0
}

f_nest_pfifo()
{
  qdiscid="$(($qdiscid + 1))"

  $check $tc qdisc add dev "$sdev" parent ${1}:${2} handle ${qdiscid}: pfifo \
    $pfifo_param

  eval $function_pfifo $1 $2

  return 0
}

# korenove qdiscy

f_root_sfq()
{
  # zavedeni korenoveho qdiscu
  $check $tc qdisc add dev "$sdev" root sfq perturb "$perturb_sfq" $sfq_param

  # spusteni uzivatelem definovane funkce
  eval $function_sfq

  return 0
}

f_root_esfq()
{
  $check $tc qdisc add dev "$sdev" root esfq perturb "$perturb_esfq" \
    $esfq_param hash "$ssd"

  eval $function_esfq

  return 0
}

f_root_prio()
{
  $check $tc qdisc add dev "$sdev" root handle 1: prio bands "$bands_prio" "$priomaps"

  # ACK pakety urcite velikosti davame do privilegovane tridy
  $check $tc filter add dev "$sdev" parent 1: prio 1 protocol ip u32 \
    match ip protocol 6 0xff \
    match u8 0x05 0x0f at 0 \
    match u16 0x0000 0xffc0 at 2 \
    match u8 0x10 0xff at 33 \
    flowid 1:1

  # spusteni uzivatelem definovane funkce
  eval $function_prio

  # spusteni pomocne funkce
  f_qdisc_prio 1

  return 0
}

f_root_tbf()
{
  $check $tc qdisc add dev "$sdev" root tbf rate "${rate_tbf}${unit_tbf}" $tbf_param

  eval $function_tbf

  return 0
}

f_root_bfifo()
{
  $check $tc qdisc add dev "$sdev" root bfifo $bfifo_param

  eval $function_bfifo

  return 0
}

f_root_pfifo()
{
  $check $tc qdisc add dev "$sdev" root pfifo $pfifo_param

  eval $function_pfifo

  return 0
}

f_root_htb()
{
  [ "$use_imq" != 'yes' ] \
  && {
    # zavedeni korenoveho qdiscu
    [ -n "$default_rate" ] \
    && {
      classid="$(($classid + 1))"
      local root_htb_param="default $classid"
    }
    $check $tc qdisc add dev "$sdev" root handle 1: htb \
      r2q "$r2q" $root_htb_param

    # zavedeni korenove tridy
    $check $tc class add dev "$sdev" parent 1: classid 1:1 \
      htb rate "${root_rate}${unit}"

    # zavedeni default tridy
    [ -n "$default_rate" ] \
      && $check $tc class add dev "$sdev" parent 1:1 classid 1:$classid \
        htb rate "${default_rate}${unit}" \
	ceil "${default_ceil}${unit}" $default_htb_param
  }

  # pakety ktere se vyhnou shaperu:
  #  pakety ktere maji nastavene jen SYN a maji urcitou velikost
  $check $iptables -t mangle -A unishaper_${iptchain} $io "$iface" -p tcp \
    --tcp-flags SYN,RST,ACK SYN -j MARK --set-mark "$notshape"
  #  pakety ktere maji nastavene jen ACK a maji urcitou velikost
  f_test_length && $dbg $iptables -t mangle -A unishaper_${iptchain} \
    $io "$iface" -p tcp --tcp-flags ALL ACK -m length \
    --length 40:100 -j MARK --set-mark "$notshape" 2>/dev/null

  # propojime pravidlo z iptables fw_markem s tridou
  $check $tc filter add dev "$sdev" parent 1: protocol ip handle \
    "$notshape" fw flowid 1:0

  # spusteni uzivatelem definovane funkce
  eval $function

  # nastaveni pro jednotlive skupiny trid
  local unum=1
  while : ; do
    qtree="_${unum}"
    f_init_htb_pom || break

    #case "$parentcl" in

    # kdyz mame seznam IP adres...
    if f_source range; then
      # kazde IP adrese (nebo skupine adres) zavedeme vlastni trubku
      for IP in $(f_range "$source_type" "$ips_source"); do
        classid="$(($classid + 1))"
        # nastavime parametry tridy
        $check $tc class add dev "$sdev" parent 1:$parentcl classid 1:$classid \
          htb rate "${rate}${unit}" ceil "${ceil}${unit}" $htb_param

        IFS=','
        for i in $IP; do
          # zavedeme pravidlo
          $check $iptables -t mangle -A unishaper_${iptchain} $io "$iface" \
	    $sd "$i" -j MARK --set-mark "$classid"
        done
        IFS="$oldifs"

        # propojime pravidlo z iptables fw_markem s tridou
        $check $tc filter add dev "$sdev" parent 1:0 protocol ip handle \
          "$classid" fw flowid 1:$classid

        # spusteni uzivatelem definovane funkce
        eval $function

        # zavedeni "vnoreneho" qdiscu
        eval $nest_qdisc_htb 1 $classid

      done
      for IP in $(f_range "$source_type" "$ips_source"); do
        IFS=','
        for i in $IP; do
          $check $iptables -t mangle -A unishaper_${iptchain} $io "$iface" \
	    $sd "$i" -j MARK --set-mark "$notshape"
        done
        IFS="$oldifs"
        eval $function
      done
      for IP in $(f_range "$source_type" "$ips_source"); do
        classid="$(($classid + 1))"
        $check $tc class add dev "$sdev" parent 1:$parentcl classid 1:$classid \
          htb rate "${rate}${unit}" ceil "${ceil}${unit}" $htb_param

        IFS=','
        for i in $IP; do
          $check $iptables -t mangle -A unishaper_${liptchain} $io "$iface" \
	    $lsd "$i" -j MARK --set-mark "$classid"
        done
        IFS="$oldifs"

        $check $tc filter add dev "$sdev" parent 1:0 protocol ip handle \
          "$classid" fw flowid 1:$classid

        eval $function

        eval $nest_qdisc_htb 1 $classid

      done

      IFS="$oldifs"
    # kdyz nemame seznam ip adres...
    else
      classid="$(($classid + 1))"
      # nastavime parametry tridy
      $check $tc class add dev "$sdev" parent 1:$parentcl classid 1:$classid \
        htb rate "${rate}${unit}" ceil "${ceil}${unit}" $htb_param

      # spusteni uzivatelem definovane funkce
      eval $function

      # kdyz se nejedna "jen" o "rodicovskou" tridu...
      [ -z "$class_name" ] \
      && {
        # propojime pravidlo z iptables fw_markem s tridou (razeni paketu
        # do teto tridy nechame na uzivatelem definovane funkci)
        $check $tc filter add dev "$sdev" parent 1:0 protocol ip \
          handle "$classid" fw flowid 1:$classid

        # nastaveni "vnoreneho" qdiscu
        eval $nest_qdisc_htb 1 $classid
      }
    fi

    local unum="$(($unum + 1))"
  done

  return 0
}

#
# hlavni smycka
#

main_loop()
{
  while : ; do
    # smazeme parametry predchoziho interfacu
    unset iface input output

    # kdyz neni nastaveny dalsi interface, koncime
    iface${inum} 2>/dev/null || { [ "$?" -eq 127 ] && return 0; }

    # kdyz neni definovan 'iface', pokracujeme na dalsi interface
    [ -z "$iface" ] && { inum="$(($inum + 1))"; continue; }

    #
    # INPUT
    #

    [ "$input" = 'yes' ] \
    && {

      # zvysime cislo virtualniho interfacu (imqCISLO)
      imqnum="$(($imqnum + 1))"

      # smazeme qdisc
      $dbg $ip link set imq$imqnum down 2>/dev/null
      $dbg $tc qdisc del dev imq$imqnum root 2>/dev/null

      [ "$stop_only" != 'yes' ] \
      && {
        f_test_ipt
        f_test_imq
        f_iptables_start
        act='in'
        f_init_global
        sdev="imq${imqnum}"
        f_root_${main_qdisc}
        $imqinit_fun
        $imqinit_fun_local
      }
    }

    #
    # OUTPUT
    #

    [ "$output" = 'yes' ] \
    && {

      # smazeme qdisc
      $dbg $tc qdisc del dev "$iface" root 2>/dev/null

      [ "$stop_only" != 'yes' ] \
      && {
        act='out'
        sdev="$iface"
        f_init_global
        f_root_${main_qdisc}
      }
    }

    inum="$(($inum + 1))"
  done

  return 0;
}


#####

progname="${0##*/}"
check='f_check'
clean='f_clean'
iptables='iptables'
tc='tc'
ip='ip'
dbg=''
echo=':'
tests='yes'
inum=0
imqnum=-1
imqnumdevs=2
ifaceid=10
action=''
oldifs="$IFS"
newline='
'

# parsovani parametru zadanych z prikazove radky
#

next=''
type=''
for i in $@; do
  [ -n "$next" ] \
  && {
    [ "$type" = 'file' ] \
    && {
      [ ! -e "$i" ] \
      && {
        perror "${i}: tento soubor neexistuje"
        exit 1
      }
    }
    eval $next=\"$i\"
    next=''; type=''
    continue
  }

  case "$i" in
    -c | --config ) next='config'; type='file' ;;
    -d | --debug ) action='dbg' ;;
    -g | --gen ) action='gen' ;;
    -G | --gen2 ) action='gen2' ;;
    -n | --nocheck ) action='nocheck' ;;
    -p | --time ) action='time' ;;
    -r | --rate ) action='rate' ;;
    -s | --stop ) stop_only='yes' ;;
    -S | --status ) action='status'; next='status'; type='' ;;
    -t | --tests ) action='tests' ;;
    --help | -help ) f_help; exit 0 ;;
    * ) echo "${progname}: ${i}: parametr neni implementovan" >&2 ;;
  esac
done

###

[ "$action" = 'status' ] \
&& {
  [ -z "$status" ] \
  && {
    perror "neni zadan nazev interfacu pro parametr -S (--status)"
    exit 1
  }
  # chceme znat jen "status", tak ho vypiseme a koncime
  f_status "$status"; exit 0
}

[ ! -e "$config" ] \
&& {
  perror "${config}: konfiguracni soubor neexistuje"
  exit 1
}

# nezadali jsme zadnou cestu (jen nazev souboru), protoze je konf. soubor
# v aktualnim adresari?
conffile="${config#*/}"
[ "$conffile" = "$config" ] && config="./$config"

. "$config"

# nenastavili jsme clean_function v konf. souboru
[ -z "$clean_function" ] && clean_function=':'

# ruzna nastaveni podle toho, co chceme provadet
case "$action" in
  nocheck ) check='' ;;
  dbg ) check='echo'; dbg='echo'; tests='no'; echo='echo' ;;
  gen ) check='echo'; dbg='echo'; tests='no'; clean=':' ;;
  gen2 ) check='echo'; dbg='echo'; tests='yes'; clean=':' ;;
  tests ) check=':'; dbg=':'; tests='yes'; clean=':' ;;
  time ) check=':'; dbg=':'; tests='no'; clean=':' ;;
  rate ) check=':'; dbg=':'; tests='no'; clean=':'; rate_control; exit 0 ;;
esac

# kdyz chceme jen uklizet, tak vsechno vycistime a jdeme
[ "$stop_only" = 'yes' ] && { f_clean; exit 0; }

# testy jestli mame vsechno co potrebujeme
f_tests

# a jedem...
main_loop

# pokud pouzivame iptables, tak ted to "zapneme"
[ "$ipt_start" = 'yes' ] \
&& {
  $check $iptables -t mangle -A PREROUTING -j unishaper_pre
  $check $iptables -t mangle -A POSTROUTING -j unishaper_post
  $check $iptables -t mangle -A INPUT -j unishaper_in
  $check $iptables -t mangle -A OUTPUT -j unishaper_out
  $check $iptables -t mangle -A FORWARD -j unishaper_fw
}

