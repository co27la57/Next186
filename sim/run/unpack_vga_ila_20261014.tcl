set inputs [lrange $argv 0 end]
open_hw_manager
foreach in $inputs {
    set out [file rootname $in]
    set data [read_hw_ila_data $in]
    puts "READ:$data"
    puts "DATAS:[get_hw_ila_datas]"
    puts "CUR:[current_hw_ila_data]"
    set data2 [lindex [get_hw_ila_datas] end]
    write_hw_ila_data -force -csv_file "$out.csv" $data2
    puts "CSV:$out.csv"
}
exit
