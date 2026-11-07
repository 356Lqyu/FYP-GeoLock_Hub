"""Approval-gated, resumable synthetic provision/run/cleanup CLI. No I/O on import."""
import argparse
import json
import os
from pathlib import Path

from fixture_state import Journal,Controller
from rpc_harness import Client,Suite,approval,demand,execution_gates


def provision(client,folder):
    journal=Journal(folder,client.receipt['run_id'])
    with journal.exclusive():
        return Controller(client,journal).provision()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--approval',type=Path,required=True)
    parser.add_argument('--output-directory',type=Path,required=True)
    parser.add_argument('--mode',choices=('provision','run','cleanup'),default='provision')
    args=parser.parse_args()
    receipt=approval(args.approval)
    execution_gates(receipt)
    demand(receipt.get('allow_identity_setup') is True,'Synthetic fixture scope not approved')
    journal=Journal(args.output_directory,receipt['run_id'])
    client=Client(receipt,os.environ['C1_PUBLIC_KEY'],os.environ['C1_SERVICE_KEY'],provisioning=True,
                  ledger=args.output_directory/'http-ledger.jsonl')
    controller=Controller(client,journal)
    with journal.exclusive():
        if args.mode=='cleanup':
            result=controller.cleanup()
        else:
            manifest=controller.provision()
            if args.mode=='run':
                demand(journal.data['test_execution']=='NOT_STARTED','Interrupted/completed test run: resume cleanup, never restart writes blindly')
                journal.data['test_execution']='STARTED'; journal.save()
                suite=Suite(client,manifest,args.output_directory/'batch-b-results.json',fixture_controller=controller)
                suite.run()
                journal.data['test_execution']='PASSED'; journal.save()
                result=controller.cleanup()
            else:
                result={'provisioning':'READY','credentials_persisted':False}
        print(json.dumps(result,indent=2))


if __name__=='__main__': main()
