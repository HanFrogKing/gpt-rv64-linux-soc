#include "Vrv64_video_timing.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {
constexpr unsigned pixels=1056*628;
constexpr std::array<uint32_t,8> palette={0xffffff,0xffff00,0x00ffff,0x00ff00,0xff00ff,0xff0000,0x0000ff,0x000000};
uint64_t checked=0,resets=0,frames=0;
void need(bool ok,const std::string &why) {if(!ok)throw std::runtime_error(why);}
void check(const Vrv64_video_timing &d,uint64_t phase,bool reset) {
 const unsigned x=reset?1055:unsigned(phase%1056);
 const unsigned y=reset?627:unsigned((phase/1056)%628);
 // Independent flattened time index; do not copy the DUT's nested counters.
 const bool de=!reset&&x<800&&y<600;
 const uint32_t rgb=de?palette[x/100]:0;
 const std::string where=" phase="+std::to_string(phase)+" reset="+std::to_string(reset);
 need(d.hpos_o==x&&d.vpos_o==y,"coordinate"+where);
 need(bool(d.de_o)==de,"active-window"+where);
 need(bool(d.hsync_o)==(!reset&&x>=840&&x<=967),"hsync-width/polarity"+where);
 need(bool(d.vsync_o)==(!reset&&y>=601&&y<=604),"vsync-width/polarity"+where);
 need(bool(d.line_start_o)==(!reset&&x==0),"line-start"+where);
 need(bool(d.frame_start_o)==(!reset&&phase%pixels==0),"frame-start"+where);
 need(d.bars_rgb_o==rgb,"color/blanking"+where);
 ++checked;
}
void reset(Vrv64_video_timing &d,bool high) {
 d.clk_i=high;d.aresetn_i=1;d.eval();
 d.aresetn_i=0;d.eval();check(d,0,true);
 d.clk_i=!high;d.eval();check(d,0,true);
 d.clk_i=0;d.eval();d.aresetn_i=1;d.eval();
 need(!d.de_o&&!d.hsync_o&&!d.vsync_o&&!d.line_start_o&&!d.frame_start_o&&d.bars_rgb_o==0,"release-before-first-edge");
 ++resets;
}
void run(Vrv64_video_timing &d,unsigned count,bool totals) {
 uint64_t active=0,hs=0,vs=0,lines=0,starts=0;
 std::array<uint64_t,8> colors{};
 for(uint64_t n=0;n<count;++n) {
  d.clk_i=1;d.eval();check(d,n,false);
  active+=d.de_o;hs+=d.hsync_o;vs+=d.vsync_o;
  lines+=d.line_start_o;starts+=d.frame_start_o;
  if(d.de_o)++colors[(n%1056)/100];
  d.clk_i=0;d.eval();check(d,n,false);
 }
 if(totals) {
  const auto f=count/pixels;
  need(count%pixels==0&&active==uint64_t(f)*480000,"frame active count");
  need(hs==uint64_t(f)*80384&&vs==uint64_t(f)*4224,"frame sync counts");
  need(lines==uint64_t(f)*628&&starts==f,"frame/line period");
  for(auto c:colors)need(c==uint64_t(f)*60000,"bar area");
  frames+=f;
 }
}
}
int main(int argc,char **argv) {
 Verilated::commandArgs(argc,argv);
 try {
  Vrv64_video_timing d;
  reset(d,false);run(d,pixels*2,true);
  // Async assertion in active pixels, all porches/sync boundaries, and wrap.
  const std::array<unsigned,14> phases={1,99,100,799,800,839,840,967,968,1055,1056*600,1056*601,1056*605,pixels-1};
  for(unsigned i=0;i<phases.size();++i) {
   reset(d,(i&1)!=0);run(d,phases[i],false);
   reset(d,(i&1)==0);run(d,1057,false);
  }
  d.final();
  std::cout<<"R95_VIDEO_TIMING_PASS checked="<<checked<<" complete_frames="<<frames<<" resets="<<resets<<" active_per_frame=480000 hs_pixels=80384 vs_pixels=4224 bars_each=60000\n";
  return 0;
 } catch(const std::exception &e) {
  std::cerr<<"R95_VIDEO_TIMING_FAIL "<<e.what()<<"\n";return 1;
 }
}
