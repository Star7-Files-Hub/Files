var total = 0;
var now = 0;
// class_type可自定义，短剧为.c_duanju，电影为.c_movies, 电视剧为.c_tvseries, 纪录片为.c_doc, 动漫为.c_anime, 学习为.c_xuexi, 体育为.c_sports, 综艺为.c_TVShows, 游戏为.c_Game, 音乐为.c_hqaudio, 电子书为.c_Ebook
var class_type = ".c_duanju";
for(var f of document.querySelectorAll("td.rowfollow.nowrap>a>img"+class_type)){
    let self = f.parentElement.parentElement.parentElement;
    let button = self.querySelector("button[data-action='addClaim']");
    let button2 = self.querySelector("button[data-action='removeClaim']");
    if(!button || button.style.display == 'none')continue
    let id = button.getAttribute("data-torrent_id");
    setTimeout(function(){
        now++;
        // 此处更改为PT站域名
        ajax.post("https://www.hdkyl.in/ajax.php", function(res){
            res = JSON.parse(res);
            if(res.ret == 0){
                button.style.display="none";
                button2.style.display="flex";
            }
            console.log('(', now, '/', total, ')', res);
        }, "action=addClaim&params%5Btorrent_id%5D="+id);
    }, 500 * total);
    total++;
}
