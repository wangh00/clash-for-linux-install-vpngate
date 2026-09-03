# VPNGate /api/iphone/ 是一种“CSV-like”格式：前 13 列固定，最后一列固定为
# Base64 OpenVPN 配置，中间 Message 允许出现逗号。这里只读取固定列和最后一列，
# 不依赖 Message 的列数。
BEGIN {
    FS = ","
    OFS = "\t"
}

/^[[:space:]]*$/ { next }
/^[*#]/ { next }

NF >= 15 {
    host = $1
    ip = $2
    score = $3 + 0
    ping = $4 + 0
    speed = $5 + 0
    country_long = $6
    country_short = toupper($7)
    config_b64 = $NF
    sub(/\r$/, "", config_b64)

    if (ip == "" || config_b64 == "") next
    if (country != "" && country_short != toupper(country)) next

    # 制表符会破坏后续 Bash TSV 读取；VPNGate 正常字段中不会出现，防御性清理。
    gsub(/\t/, " ", host)
    gsub(/\t/, " ", ip)
    gsub(/\t/, " ", country_long)

    print score, speed, ping, country_short, ip, host, config_b64
}

