#include <stdio.h>
#include <stdlib.h>
int main(void) {
    char *p=malloc(32);
    if (!p) return 1;
    p[0]='O';p[1]='K';p[2]=0;
    printf("RV64IMA musl %s\n",p);
    free(p);
    return 0;
}
