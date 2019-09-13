import {Pager} from '@eg/share/util/pager';
import {Component, Input, ViewChild} from '@angular/core';
import { Router, ActivatedRoute }    from '@angular/router';
import {IdlService, IdlObject} from '@eg/core/idl.service';
import {GridDataSource} from '@eg/share/grid/grid';
import {GridComponent} from '@eg/share/grid/grid.component';
import {ToastService} from '@eg/share/toast/toast.service';
import {PcrudService} from '@eg/core/pcrud.service';
import {OrgService} from '@eg/core/org.service';
import {PermService} from '@eg/core/perm.service';
import {AuthService} from '@eg/core/auth.service';
import { AdminPageComponent } from '../../../share/admin-page/admin-page.component';

 @Component({
     templateUrl: './floating-group.component.html'
 })

 export class FloatingGroupComponent extends AdminPageComponent {

    idlClass = 'cfg';
    @Input() sortField: string;
    @Input() dialogSize: 'sm' | 'lg' = 'lg';

    gridDataSource: GridDataSource = new GridDataSource();
    
    @ViewChild('grid', {static: true}) grid: GridComponent;

    constructor(
        route: ActivatedRoute,
        idl: IdlService,
        org: OrgService,
        auth: AuthService,
        pcrud: PcrudService,
        perm: PermService,
        toast: ToastService,
        private router:Router
    ) {
        super(route, idl, org, auth, pcrud, perm, toast);
    }

    ngOnInit() {
        super.ngOnInit();
        this.gridDataSource.getRows = (pager: Pager, sort: any[]) => {
            const searchOps = {
                offset: pager.offset,
                limit: pager.limit,
                order_by: {}
            };
            return this.pcrud.retrieveAll("cfg", searchOps);
        };
        this.grid.onRowActivate.subscribe(
            (idlThing: IdlObject) => {
                let idToEdit = idlThing.a[0];
                this.navigateToEditPage(idToEdit);
            }
        );
    }

    createNew = () => {
        super.createNew();
    };

    editSelected = (floatingGroups: IdlObject[]) => {
        let idToEdit = floatingGroups[0].a[0];
        this.navigateToEditPage(idToEdit);
    }

    deleteSelected = (floatingGroups: IdlObject[]) => {
        super.deleteSelected(floatingGroups);
    }

    navigateToEditPage(id: any) {
        this.router.navigate(["/staff/admin/server/config/floating_group/" + id]);
    }

    // this was left mostly blank to ensure a modal does not open for edits
    showEditDialog(idlThing: IdlObject): Promise<any> {
        return;
    }

 }